//
//  MirageHostService+QueueBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Queue/lock bridge helpers used by the host hot path.
//

import Foundation
import Network
import MirageKit

#if os(macOS)

extension MirageHostService {
    nonisolated func controlWorker(for clientID: UUID) -> SerialWorker {
        controlWorkersByClientID.withLock { workers in
            if let existing = workers[clientID] {
                return existing
            }
            let worker = SerialWorker(
                label: "com.mirage.host.control.\(clientID.uuidString.lowercased())",
                qos: .userInitiated
            )
            workers[clientID] = worker
            return worker
        }
    }

    nonisolated func dispatchControlWork(
        clientID: UUID,
        completion: (@Sendable () -> Void)? = nil,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) {
        let worker = controlWorker(for: clientID)
        worker.submit {
            Task(priority: .userInitiated) { @MainActor in
                await work()
                completion?()
            }
        }
    }

    nonisolated func dispatchMainWork(
        completion: (@Sendable () -> Void)? = nil,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) {
        transportWorker.submit {
            Task(priority: .userInitiated) { @MainActor in
                await work()
                completion?()
            }
        }
    }

    nonisolated func storeReceiveLoop(
        _ loop: HostReceiveLoop,
        sessionID: UUID
    ) {
        receiveLoopsBySessionID.withLock { loops in
            loops[sessionID] = loop
        }
    }

    nonisolated func removeReceiveLoop(sessionID: UUID) {
        receiveLoopsBySessionID.withLock { loops in
            loops.removeValue(forKey: sessionID)
        }
    }

    nonisolated func stopReceiveLoop(sessionID: UUID) {
        let loop = receiveLoopsBySessionID.withLock { loops in
            loops.removeValue(forKey: sessionID)
        }
        loop?.stop()
    }

    @MainActor
    func removeControlWorker(clientID: UUID) {
        controlWorkersByClientID.withLock { workers in
            workers.removeValue(forKey: clientID)
        }
    }

    @MainActor
    func registerTypingBurstRoute(streamID: StreamID, context: StreamContext) {
        streamRegistry.registerTypingBurstHandler(streamID: streamID) { [weak context] in
            Task(priority: .userInitiated) {
                await context?.noteTypingBurstActivity()
            }
        }
    }

    @MainActor
    func unregisterTypingBurstRoute(streamID: StreamID) {
        streamRegistry.unregisterTypingBurstHandler(streamID: streamID)
    }

    @MainActor
    func registerStallWindowPointerRoute(streamID: StreamID, context: StreamContext) async {
        streamRegistry.registerPointerCoalescingRoute(streamID: streamID)
        await context.setCaptureStallStageHandler { [weak self] stage in
            self?.streamRegistry.noteCaptureStallStage(
                streamID: streamID,
                stage: stage
            )
        }
    }

    @MainActor
    func unregisterStallWindowPointerRoute(streamID: StreamID) {
        streamRegistry.unregisterPointerCoalescingRoute(streamID: streamID)
    }

    nonisolated func sendAudioPacketForClient(_ clientID: UUID, data: Data) {
        transportRegistry.sendAudio(clientID: clientID, data: data)
    }
}

#endif
