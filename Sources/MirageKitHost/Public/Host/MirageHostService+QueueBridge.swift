//
//  MirageHostService+QueueBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Queue/lock bridge helpers used by the host hot path.
//

import Dispatch
import Foundation
import MirageKit

#if os(macOS)

extension MirageHostService {
    /// Returns the serial control queue assigned to a client, creating one on first use.
    nonisolated func controlQueue(for clientID: UUID) -> DispatchQueue {
        controlQueuesByClientID.withLock { queues in
            if let existing = queues[clientID] {
                return existing
            }
            let queue = DispatchQueue(
                label: "com.mirage.host.control.\(clientID.uuidString.lowercased())",
                qos: .userInitiated
            )
            queues[clientID] = queue
            return queue
        }
    }

    /// Schedules client-scoped control work so one client's sends remain ordered.
    nonisolated func dispatchControlWork(
        clientID: UUID,
        completion: (@Sendable () -> Void)? = nil,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) {
        let queue = controlQueue(for: clientID)
        queue.async {
            Task(priority: .userInitiated) { @MainActor in
                await work()
                completion?()
            }
        }
    }

    /// Schedules main-actor work on the shared host transport worker.
    nonisolated func dispatchMainWork(
        completion: (@Sendable () -> Void)? = nil,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) {
        transportQueue.async {
            Task(priority: .userInitiated) { @MainActor in
                await work()
                completion?()
            }
        }
    }

    /// Stores the receive loop that owns a bootstrapped control session.
    nonisolated func storeReceiveLoop(
        _ loop: HostReceiveLoop,
        sessionID: UUID
    ) {
        receiveLoopsBySessionID.withLock { loops in
            loops[sessionID] = loop
        }
    }

    /// Removes a receive loop without stopping it.
    nonisolated func removeReceiveLoop(sessionID: UUID) {
        receiveLoopsBySessionID.withLock { loops in
            loops[sessionID] = nil
        }
    }

    /// Stops and removes the receive loop for a control session.
    nonisolated func stopReceiveLoop(sessionID: UUID) {
        let loop = receiveLoopsBySessionID.withLock { loops in
            loops.removeValue(forKey: sessionID)
        }
        loop?.stop()
    }

    /// Stores the priority input route that owns local-UDP input for a session.
    nonisolated func storePriorityInputRoute(
        _ route: HostPriorityInputRoute,
        sessionID: UUID
    ) {
        priorityInputRoutesBySessionID.withLock { routes in
            routes[sessionID]?.stop()
            routes[sessionID] = route
        }
    }

    /// Stops and removes the priority input route for a control session.
    nonisolated func stopPriorityInputRoute(sessionID: UUID) {
        let route = priorityInputRoutesBySessionID.withLock { routes in
            routes.removeValue(forKey: sessionID)
        }
        route?.stop()
    }

}

#endif
