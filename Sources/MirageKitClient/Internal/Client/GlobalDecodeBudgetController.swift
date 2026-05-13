//
//  GlobalDecodeBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

actor GlobalDecodeBudgetController {
    /// Maximum number of decode submissions allowed to run concurrently.
    private static let inFlightLimit: Int = {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }()

    struct Lease {
        let id: UInt64
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Lease, Never>
    }

    static let shared = GlobalDecodeBudgetController()

    private var streamTierByID: [StreamID: StreamPresentationTier] = [:]
    private var activeWaiters: [Waiter] = []
    private var passiveWaiters: [Waiter] = []
    private var activeLeaseIDs = Set<UInt64>()
    private var nextLeaseID: UInt64 = 0

    func register(streamID: StreamID, tier: StreamPresentationTier) {
        streamTierByID[streamID] = tier
    }

    func unregister(streamID: StreamID) {
        streamTierByID.removeValue(forKey: streamID)
    }

    func updateTier(streamID: StreamID, tier: StreamPresentationTier) {
        streamTierByID[streamID] = tier
    }

    func acquire(streamID: StreamID) async -> Lease {
        if activeLeaseIDs.count < Self.inFlightLimit,
           activeWaiters.isEmpty,
           passiveWaiters.isEmpty {
            return issueLease()
        }

        return await withCheckedContinuation { continuation in
            let tier = streamTierByID[streamID] ?? .activeLive
            let waiter = Waiter(continuation: continuation)
            if tier == .activeLive {
                activeWaiters.append(waiter)
            } else {
                passiveWaiters.append(waiter)
            }
        }
    }

    func release(_ lease: Lease) {
        guard activeLeaseIDs.remove(lease.id) != nil else { return }
        grantQueuedWaitersIfPossible()
    }

    private func issueLease() -> Lease {
        nextLeaseID &+= 1
        let lease = Lease(id: nextLeaseID)
        activeLeaseIDs.insert(lease.id)
        return lease
    }

    private func grantQueuedWaitersIfPossible() {
        while activeLeaseIDs.count < Self.inFlightLimit {
            let waiter: Waiter? = if !activeWaiters.isEmpty {
                activeWaiters.removeFirst()
            } else if !passiveWaiters.isEmpty {
                passiveWaiters.removeFirst()
            } else {
                nil
            }

            guard let waiter else { return }
            waiter.continuation.resume(returning: issueLease())
        }
    }
}
