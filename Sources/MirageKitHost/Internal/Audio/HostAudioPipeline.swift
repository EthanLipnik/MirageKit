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
    private var processingTask: Task<Void, Never>?
    private var isRunning = true
    private let maxQueuedBuffers: Int

    init(
        sourceStreamID: StreamID,
        audioConfiguration: MirageAudioConfiguration,
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext?,
        maxQueuedBuffers: Int = 48,
        onPacketsReady: @escaping @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    ) {
        self.sourceStreamID = sourceStreamID
        encoder = AudioEncoder(audioConfiguration: audioConfiguration)
        packetizer = AudioPacketizer(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext
        )
        self.maxQueuedBuffers = max(4, maxQueuedBuffers)
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
        if queue.count >= maxQueuedBuffers {
            // Under pressure, drop the oldest audio chunk to protect video transport.
            queue.removeFirst()
        }
        queue.append(buffer)
        startProcessingIfNeeded()
    }

    func stop() {
        isRunning = false
        queue.removeAll()
        processingTask?.cancel()
        processingTask = nil
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
            guard let encoded = await encoder.encode(captured) else { continue }
            let currentStreamID = sourceStreamID
            let packets = await packetizer.packetize(frame: encoded, streamID: currentStreamID)
            guard !packets.isEmpty else { continue }
            await onPacketsReady(packets, encoded, currentStreamID)
        }
    }
}

#endif
