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
    private let onPacketsReady: @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    private var sourceStreamID: StreamID
    private var queue: [CapturedAudioBuffer] = []
    private var queuedDurationSeconds: Double = 0
    private var pendingDiscontinuity = false
    private var droppedBufferCount: UInt64 = 0
    private var lastDropLogTime: CFAbsoluteTime = 0
    private var processingTask: Task<Void, Never>?
    private var isRunning = true
    private let maxQueuedDurationSeconds: Double

    init(
        sourceStreamID: StreamID,
        audioConfiguration: MirageAudioConfiguration,
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext?,
        maxQueuedDurationSeconds: Double = 0.120,
        onPacketsReady: @escaping @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    ) {
        self.sourceStreamID = sourceStreamID
        encoder = AudioEncoder(audioConfiguration: audioConfiguration)
        packetizer = AudioPacketizer(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext
        )
        self.maxQueuedDurationSeconds = max(0.020, maxQueuedDurationSeconds)
        self.onPacketsReady = onPacketsReady
    }

    func updateConfiguration(_ configuration: MirageAudioConfiguration) async {
        await encoder.updateConfiguration(configuration)
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
        startProcessingIfNeeded()
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
        processingTask = Task(priority: .utility) { [weak self] in
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
            guard let encoded = await encoder.encode(captured) else { continue }
            let currentStreamID = sourceStreamID
            let discontinuity = pendingDiscontinuity
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

    private static func durationSeconds(for buffer: CapturedAudioBuffer) -> Double {
        guard buffer.sampleRate > 0, buffer.frameCount > 0 else { return 0.010 }
        return Double(buffer.frameCount) / buffer.sampleRate
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
}

#endif
