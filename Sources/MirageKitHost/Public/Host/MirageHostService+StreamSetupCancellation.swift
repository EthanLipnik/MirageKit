//
//  MirageHostService+StreamSetupCancellation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/24/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Unique key for a cancellable stream setup request within a client session.
    struct StreamSetupCancellationKey: Hashable {
        let clientSessionID: UUID
        let startupRequestID: UUID
    }

    /// Tracks active and cancelled setup requests for one client session.
    struct StreamSetupSessionLifecycle {
        var activeRequestIDs: Set<UUID> = []
        var cancelledRequestIDs: Set<UUID> = []
        var sessionClosing = false
    }

    /// Registers a stream setup request and returns whether it may continue.
    func beginStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) -> Bool {
        var lifecycle = streamSetupLifecycleBySessionID[clientSessionID] ?? StreamSetupSessionLifecycle()
        lifecycle.activeRequestIDs.insert(startupRequestID)
        let isCancelled = lifecycle.sessionClosing || lifecycle.cancelledRequestIDs.contains(startupRequestID)
        if isCancelled {
            lifecycle.cancelledRequestIDs.insert(startupRequestID)
            cancelledStreamSetupRequestIDs.insert(StreamSetupCancellationKey(
                clientSessionID: clientSessionID,
                startupRequestID: startupRequestID
            ))
        }
        streamSetupLifecycleBySessionID[clientSessionID] = lifecycle
        return !isCancelled
    }

    /// Cancels one in-flight stream setup request.
    func cancelStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) {
        var lifecycle = streamSetupLifecycleBySessionID[clientSessionID] ?? StreamSetupSessionLifecycle()
        lifecycle.cancelledRequestIDs.insert(startupRequestID)
        streamSetupLifecycleBySessionID[clientSessionID] = lifecycle
        cancelledStreamSetupRequestIDs.insert(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }

    /// Cancels every active stream setup request for a client session.
    func cancelAllStreamSetup(clientSessionID: UUID) {
        var lifecycle = streamSetupLifecycleBySessionID[clientSessionID] ?? StreamSetupSessionLifecycle()
        lifecycle.cancelledRequestIDs.formUnion(lifecycle.activeRequestIDs)
        for startupRequestID in lifecycle.activeRequestIDs {
            cancelledStreamSetupRequestIDs.insert(StreamSetupCancellationKey(
                clientSessionID: clientSessionID,
                startupRequestID: startupRequestID
            ))
        }
        streamSetupLifecycleBySessionID[clientSessionID] = lifecycle
    }

    /// Marks a client session as closing so all current and future setup requests fail closed.
    func markStreamSetupSessionClosing(clientSessionID: UUID) {
        var lifecycle = streamSetupLifecycleBySessionID[clientSessionID] ?? StreamSetupSessionLifecycle()
        lifecycle.sessionClosing = true
        lifecycle.cancelledRequestIDs.formUnion(lifecycle.activeRequestIDs)
        for startupRequestID in lifecycle.activeRequestIDs {
            cancelledStreamSetupRequestIDs.insert(StreamSetupCancellationKey(
                clientSessionID: clientSessionID,
                startupRequestID: startupRequestID
            ))
        }
        streamSetupLifecycleBySessionID[clientSessionID] = lifecycle
    }

    /// Returns whether a stream setup request has been cancelled or superseded.
    func isStreamSetupCancelled(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) -> Bool {
        if let lifecycle = streamSetupLifecycleBySessionID[clientSessionID],
           lifecycle.sessionClosing || lifecycle.cancelledRequestIDs.contains(startupRequestID) {
            return true
        }
        return cancelledStreamSetupRequestIDs.contains(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }

    /// Completes stream setup bookkeeping and clears the cancellation marker.
    func finishStreamSetup(
        clientSessionID: UUID,
        startupRequestID: UUID
    ) {
        if var lifecycle = streamSetupLifecycleBySessionID[clientSessionID] {
            lifecycle.activeRequestIDs.remove(startupRequestID)
            lifecycle.cancelledRequestIDs.remove(startupRequestID)
            if lifecycle.activeRequestIDs.isEmpty,
               lifecycle.cancelledRequestIDs.isEmpty,
               !lifecycle.sessionClosing {
                streamSetupLifecycleBySessionID.removeValue(forKey: clientSessionID)
            } else {
                streamSetupLifecycleBySessionID[clientSessionID] = lifecycle
            }
        }
        cancelledStreamSetupRequestIDs.remove(StreamSetupCancellationKey(
            clientSessionID: clientSessionID,
            startupRequestID: startupRequestID
        ))
    }
}
#endif
