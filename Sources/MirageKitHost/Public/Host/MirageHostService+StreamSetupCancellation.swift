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
    struct StreamSetupCancellationKey: Hashable {
        let clientSessionID: UUID
        let startupRequestID: UUID
    }

    struct StreamSetupSessionLifecycle {
        var activeRequestIDs: Set<UUID> = []
        var cancelledRequestIDs: Set<UUID> = []
        var sessionClosing = false
    }

    @discardableResult
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
