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
            Task(priority: .userInitiated) {
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
            Task(priority: .userInitiated) {
                await work()
                completion?()
            }
        }
    }

    nonisolated func storeReceiveLoop(
        _ loop: HostReceiveLoop,
        connectionID: ObjectIdentifier
    ) {
        receiveLoopsByConnectionID.withLock { loops in
            loops[connectionID] = loop
        }
    }

    nonisolated func removeReceiveLoop(connectionID: ObjectIdentifier) {
        receiveLoopsByConnectionID.withLock { loops in
            loops.removeValue(forKey: connectionID)
        }
    }

    nonisolated func stopReceiveLoop(connectionID: ObjectIdentifier) {
        let loop = receiveLoopsByConnectionID.withLock { loops in
            loops.removeValue(forKey: connectionID)
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

    nonisolated func sendVideoPacketForStream(
        _ streamID: StreamID,
        data: Data,
        onComplete: (@Sendable (NWError?) -> Void)? = nil
    ) {
        transportRegistry.sendVideo(streamID: streamID, data: data, onComplete: onComplete)
    }

    nonisolated func sendAudioPacketForClient(_ clientID: UUID, data: Data) {
        transportRegistry.sendAudio(clientID: clientID, data: data)
    }
}

#endif
