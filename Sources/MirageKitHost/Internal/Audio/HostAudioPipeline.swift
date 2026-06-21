//
//  HostAudioPipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Per-client host audio encode + packet send pipeline.
//

import Foundation
import MirageKit

#if os(macOS)

actor HostAudioPipeline {
    private let encoder: AudioEncoder
    private let packetizer: AudioPacketizer
    private var qualityGovernor: HostAudioQualityGovernor
    private let onPacketsReady: @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    private var sourceStreamID: StreamID
    private var queue: [CapturedAudioBuffer] = []
    private var queuedDurationSeconds: Double = 0
    private var pendingProfile: ResolvedAudioStreamProfile?
    private var pendingDiscontinuity = false
    private var droppedBufferCount: UInt64 = 0
    private var lastDropLogTime: CFAbsoluteTime = 0
    private var processingTask: Task<Void, Never>?
    private var isRunning = true
    private let maxQueuedDurationSeconds: Double

    init(
        sourceStreamID: StreamID,
        audioConfiguration: MirageAudioConfiguration,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext?,
        maxQueuedDurationSeconds: Double = 0.120,
        onPacketsReady: @escaping @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    ) {
        self.sourceStreamID = sourceStreamID
        encoder = AudioEncoder(audioConfiguration: audioConfiguration)
        qualityGovernor = HostAudioQualityGovernor(
            configuration: audioConfiguration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
        pendingProfile = qualityGovernor.profile
        packetizer = AudioPacketizer(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext
        )
        self.maxQueuedDurationSeconds = max(0.020, maxQueuedDurationSeconds)
        self.onPacketsReady = onPacketsReady
        Self.logResolvedProfile(qualityGovernor.profile, reason: "start")
    }

    func updateConfiguration(
        _ configuration: MirageAudioConfiguration,
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile
    ) async {
        let profile = qualityGovernor.updateConfiguration(
            configuration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
        await encoder.updateProfile(profile, configuration: configuration)
        pendingProfile = nil
        Self.logResolvedProfile(qualityGovernor.profile, reason: "update")
    }

    func updateSourceStreamID(_ streamID: StreamID) {
        sourceStreamID = streamID
    }

    func enqueue(_ buffer: CapturedAudioBuffer) {
        guard isRunning else { return }
        queue.append(buffer)
        queuedDurationSeconds += Self.durationSeconds(for: buffer)
        let droppedCount = Self.trimQueuedBuffers(
            &queue,
            queuedDurationSeconds: &queuedDurationSeconds,
            maxQueuedDurationSeconds: maxQueuedDurationSeconds
        )
        if droppedCount > 0 {
            pendingDiscontinuity = true
            droppedBufferCount &+= UInt64(droppedCount)
            logDropsIfNeeded()
        }
        if let profile = qualityGovernor.recordQueueState(
            queuedDurationSeconds: queuedDurationSeconds,
            droppedBuffers: droppedCount,
            maxQueuedDurationSeconds: maxQueuedDurationSeconds
        ) {
            pendingProfile = profile
        }
        startProcessingIfNeeded()
    }

    func recordTransportPressure() {
        if let profile = qualityGovernor.recordTransportPressure() {
            pendingProfile = profile
        }
    }

    func recordReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) {
        if let profile = qualityGovernor.recordReceiverFeedback(feedback) {
            pendingProfile = profile
        }
    }

    func stop() {
        isRunning = false
        queue.removeAll()
        queuedDurationSeconds = 0
        pendingDiscontinuity = false
        processingTask?.cancel()
        processingTask = nil
    }

    nonisolated static func trimQueuedBuffers(
        _ queue: inout [CapturedAudioBuffer],
        queuedDurationSeconds: inout Double,
        maxQueuedDurationSeconds: Double
    ) -> Int {
        let budget = max(0.001, maxQueuedDurationSeconds)
        var droppedCount = 0
        while queuedDurationSeconds > budget, queue.count > 1 {
            let removed = queue.removeFirst()
            queuedDurationSeconds = max(0, queuedDurationSeconds - durationSeconds(for: removed))
            droppedCount += 1
        }
        return droppedCount
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.processLoop()
        }
    }

    private func processLoop() async {
        defer { processingTask = nil }
        while isRunning {
            guard !queue.isEmpty else { return }
            let captured = queue.removeFirst()
            queuedDurationSeconds = max(0, queuedDurationSeconds - Self.durationSeconds(for: captured))
            switch qualityGovernor.activityDecision(for: captured) {
            case .send:
                break
            case .gated:
                continue
            }
            await applyPendingProfileIfNeeded()
            let encodedFrames = await encoder.encode(captured)
            guard !encodedFrames.isEmpty else { continue }
            if let profile = qualityGovernor.recordSuccessfulFrame() {
                pendingProfile = profile
            }
            let currentStreamID = sourceStreamID
            for (index, encoded) in encodedFrames.enumerated() {
                let discontinuity = pendingDiscontinuity && index == 0
                let packets = await packetizer.packetize(
                    frame: encoded,
                    streamID: currentStreamID,
                    discontinuity: discontinuity
                )
                if discontinuity {
                    pendingDiscontinuity = false
                }
                guard !packets.isEmpty else { continue }
                await onPacketsReady(packets, encoded, currentStreamID)
            }
        }
    }

    private func applyPendingProfileIfNeeded() async {
        guard let pendingProfile else { return }
        self.pendingProfile = nil
        pendingDiscontinuity = true
        await encoder.updateResolvedProfile(pendingProfile)
    }

    private static func durationSeconds(for buffer: CapturedAudioBuffer) -> Double {
        buffer.durationSeconds
    }

    private func logDropsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastDropLogTime == 0 || now - lastDropLogTime > 2.0 else { return }
        MirageLogger.host(
            "Audio queue drop: dropped \(droppedBufferCount) stale buffer(s), queuedMs=\(Int((queuedDurationSeconds * 1000).rounded()))"
        )
        droppedBufferCount = 0
        lastDropLogTime = now
    }

    private nonisolated static func logResolvedProfile(_ profile: ResolvedAudioStreamProfile?, reason: String) {
        guard let profile else {
            MirageLogger.host("Audio resolved profile unavailable reason=\(reason)")
            return
        }
        MirageLogger.host(
            "Audio resolved profile reason=\(reason) codec=\(profile.codec) " +
                "quality=\(profile.quality.rawValue) sampleRate=\(Int(profile.sampleRate.rounded())) " +
                "channels=\(profile.channelCount) bitrate=\(profile.bitrateBps.map(String.init) ?? "lossless") " +
                "floor=\(profile.minimumBitrateBps.map(String.init) ?? "none") " +
                "ceiling=\(profile.maximumBitrateBps.map(String.init) ?? "none") " +
                "adaptive=\(profile.adaptiveCompressionEnabled) policy=\(profile.reason)"
        )
    }
}

#endif
