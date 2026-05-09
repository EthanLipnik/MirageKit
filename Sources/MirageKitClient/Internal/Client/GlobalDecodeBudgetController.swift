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
        let generation: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let streamID: StreamID
        let generation: UInt64
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private struct ActiveLease {
        let streamID: StreamID
        let generation: UInt64
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
    private var streamGenerationByID: [StreamID: UInt64] = [:]
    private var activeWaiters: [Waiter] = []
    private var passiveWaiters: [Waiter] = []
    private var activeLeasesByID: [UInt64: ActiveLease] = [:]
    private var nextLeaseID: UInt64 = 0

    func register(streamID: StreamID, tier: StreamPresentationTier) {
        streamTierByID[streamID] = tier
        streamGenerationByID[streamID, default: 0] &+= 1
    }

    func unregister(streamID: StreamID) {
        streamTierByID.removeValue(forKey: streamID)
        streamGenerationByID[streamID, default: 0] &+= 1
        cancelWaiters(streamID: streamID)
        activeLeasesByID = activeLeasesByID.filter { _, lease in
            lease.streamID != streamID
        }
        grantQueuedWaitersIfPossible()
    }

    func updateTier(streamID: StreamID, tier: StreamPresentationTier) {
        streamTierByID[streamID] = tier
        reprioritizeWaiters(streamID: streamID)
    }

    func acquire(streamID: StreamID) async -> Lease? {
        nextLeaseID &+= 1
        let id = nextLeaseID
        guard let generation = streamGenerationByID[streamID],
              streamTierByID[streamID] != nil else {
            return nil
        }
        if canGrantImmediately {
            return issueLease(id: id, streamID: streamID, generation: generation)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }

                let tier = streamTierByID[streamID] ?? .activeLive
                let waiter = Waiter(
                    id: id,
                    streamID: streamID,
                    generation: generation,
                    continuation: continuation
                )
                if tier == .activeLive {
                    activeWaiters.append(waiter)
                } else {
                    passiveWaiters.append(waiter)
                }
                grantQueuedWaitersIfPossible()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release(_ lease: Lease) {
        guard let activeLease = activeLeasesByID[lease.id],
              activeLease.streamID == lease.streamID,
              activeLease.generation == lease.generation else {
            return
        }
        activeLeasesByID.removeValue(forKey: lease.id)
        grantQueuedWaitersIfPossible()
    }

    private var canGrantImmediately: Bool {
        activeLeasesByID.count < inFlightLimit && activeWaiters.isEmpty && passiveWaiters.isEmpty
    }

    private func issueLease(id: UInt64, streamID: StreamID, generation: UInt64) -> Lease {
        let lease = Lease(id: id, streamID: streamID, generation: generation)
        activeLeasesByID[lease.id] = ActiveLease(streamID: streamID, generation: generation)
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
            guard streamTierByID[waiter.streamID] != nil,
                  streamGenerationByID[waiter.streamID] == waiter.generation else {
                waiter.continuation.resume(returning: nil)
                continue
            }
            waiter.continuation.resume(returning: issueLease(
                id: waiter.id,
                streamID: waiter.streamID,
                generation: waiter.generation
            ))
        }
    }

    private func cancelWaiter(id: UInt64) {
        if let index = activeWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = activeWaiters.remove(at: index)
            waiter.continuation.resume(returning: nil)
            return
        }
        if let index = passiveWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = passiveWaiters.remove(at: index)
            waiter.continuation.resume(returning: nil)
        }
    }

    private func cancelWaiters(streamID: StreamID) {
        let active = activeWaiters.filter { $0.streamID == streamID }
        let passive = passiveWaiters.filter { $0.streamID == streamID }
        activeWaiters.removeAll { $0.streamID == streamID }
        passiveWaiters.removeAll { $0.streamID == streamID }
        for waiter in active + passive {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func reprioritizeWaiters(streamID: StreamID) {
        let tier = streamTierByID[streamID] ?? .activeLive
        let movedActive = activeWaiters.filter { $0.streamID == streamID }
        let movedPassive = passiveWaiters.filter { $0.streamID == streamID }
        let moved = movedActive + movedPassive
        guard !moved.isEmpty else { return }

        activeWaiters.removeAll { $0.streamID == streamID }
        passiveWaiters.removeAll { $0.streamID == streamID }
        if tier == .activeLive {
            activeWaiters.append(contentsOf: moved)
        } else {
            passiveWaiters.append(contentsOf: moved)
        }
    }
}
