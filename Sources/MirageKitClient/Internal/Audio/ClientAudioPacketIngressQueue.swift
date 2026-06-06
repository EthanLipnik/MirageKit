//
//  ClientAudioPacketIngressQueue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Off-main audio packet ingress queue that decodes packets and discards stale generations.
final class ClientAudioPacketIngressQueue: @unchecked Sendable {
    /// Main-actor callback used to hand decoded PCM frames back to playback state.
    typealias DeliverDecodedFrames = @MainActor @Sendable ([DecodedPCMFrame], StreamID) -> Void

    /// Lock-protected state shared by the queue closure and owner-facing methods.
    private final class SharedState: @unchecked Sendable {
        /// Mutable generation and delivery target guarded by `lock`.
        private struct State {
            var generation: UInt64 = 0
            var deliverHandler: DeliverDecodedFrames?
        }

        private let lock = NSLock()
        private var state = State()

        func setDeliverHandler(_ handler: @escaping DeliverDecodedFrames) {
            withLock { $0.deliverHandler = handler }
        }

        var currentGeneration: UInt64 {
            withLock { $0.generation }
        }

        func invalidatePendingPackets() {
            withLock { $0.generation &+= 1 }
        }

        var deliverySnapshot: (generation: UInt64, handler: DeliverDecodedFrames?) {
            withLock { state in
                (generation: state.generation, handler: state.deliverHandler)
            }
        }

        private func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }
    }

    /// Work captured at enqueue time so reset operations can invalidate older packets.
    private struct WorkItem: Sendable {
        let header: MirageWire.AudioPacketHeader
        let payload: Data
        let targetChannelCount: Int
        let generation: UInt64
    }

    private let pipeline: ClientAudioDecodePipeline
    private let sharedState: SharedState
    private let queue: MirageAsyncDispatchQueue<WorkItem>

    init(pipeline: ClientAudioDecodePipeline) {
        self.pipeline = pipeline
        let sharedState = SharedState()
        self.sharedState = sharedState
        queue = MirageAsyncDispatchQueue(priority: .userInitiated) { item in
            guard item.generation == sharedState.currentGeneration else { return }

            let decodedFrames = await pipeline.ingestPacket(
                header: item.header,
                payload: item.payload,
                targetChannelCount: item.targetChannelCount
            )
            guard !decodedFrames.isEmpty else { return }

            let delivery = sharedState.deliverySnapshot
            guard item.generation == delivery.generation, let handler = delivery.handler else { return }
            await handler(decodedFrames, item.header.streamID)
        }
    }

    func setDeliverHandler(_ handler: @escaping DeliverDecodedFrames) {
        sharedState.setDeliverHandler(handler)
    }

    var currentGeneration: UInt64 {
        sharedState.currentGeneration
    }

    func invalidatePendingPackets() {
        sharedState.invalidatePendingPackets()
    }

    func reset() async {
        invalidatePendingPackets()
        await pipeline.reset()
    }

    func enqueue(
        header: MirageWire.AudioPacketHeader,
        payload: Data,
        targetChannelCount: Int,
        generation: UInt64
    ) {
        queue.yield(
            WorkItem(
                header: header,
                payload: payload,
                targetChannelCount: max(1, targetChannelCount),
                generation: generation
            )
        )
    }
}
