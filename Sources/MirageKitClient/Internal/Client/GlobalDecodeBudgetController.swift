//
//  GlobalDecodeBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

actor GlobalDecodeBudgetController {
    struct Lease: Sendable {
        let id: UInt64
        let streamID: StreamID
    }

    private struct Waiter {
        let streamID: StreamID
        let continuation: CheckedContinuation<Lease, Never>
    }

    static let shared = GlobalDecodeBudgetController()

    private let inFlightLimit: Int = {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }()

    private var streamTierByID: [StreamID: StreamPresentationTier] = [:]
    private var activeWaiters: [Waiter] = []
    private var passiveWaiters: [Waiter] = []
    private var activeLeasesByID: [UInt64: StreamID] = [:]
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
        if canGrantImmediately {
            return issueLease(streamID: streamID)
        }

        return await withCheckedContinuation { continuation in
            let tier = streamTierByID[streamID] ?? .activeLive
            let waiter = Waiter(streamID: streamID, continuation: continuation)
            if tier == .activeLive {
                activeWaiters.append(waiter)
            } else {
                passiveWaiters.append(waiter)
            }
        }
    }

    func release(_ lease: Lease) {
        guard activeLeasesByID.removeValue(forKey: lease.id) != nil else { return }
        grantQueuedWaitersIfPossible()
    }

    private var canGrantImmediately: Bool {
        activeLeasesByID.count < inFlightLimit && activeWaiters.isEmpty && passiveWaiters.isEmpty
    }

    private func issueLease(streamID: StreamID) -> Lease {
        nextLeaseID &+= 1
        let lease = Lease(id: nextLeaseID, streamID: streamID)
        activeLeasesByID[lease.id] = streamID
        return lease
    }

    private func grantQueuedWaitersIfPossible() {
        while activeLeasesByID.count < inFlightLimit {
            let waiter: Waiter?
            if !activeWaiters.isEmpty {
                waiter = activeWaiters.removeFirst()
            } else if !passiveWaiters.isEmpty {
                waiter = passiveWaiters.removeFirst()
            } else {
                waiter = nil
            }

            guard let waiter else { return }
            waiter.continuation.resume(returning: issueLease(streamID: waiter.streamID))
        }
    }
}
