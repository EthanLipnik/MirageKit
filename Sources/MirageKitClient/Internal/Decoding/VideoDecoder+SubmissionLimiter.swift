//
//  VideoDecoder+SubmissionLimiter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  HEVC decoder submission limiter extensions.
//

import Foundation
import MirageKit

extension VideoDecoder {
    struct DecodeSubmissionLease: Sendable, Equatable {
        let id: UInt64
        let generation: UInt64
    }

    struct DecodeSubmissionWaiter: Sendable {
        let id: UInt64
        let generation: UInt64
        let continuation: CheckedContinuation<DecodeSubmissionLease?, Never>
    }

    func setDecodeSubmissionLimit(targetFrameRate: Int) {
        let desiredLimit = Self.baselineDecodeSubmissionLimit(targetFrameRate: targetFrameRate)
        setDecodeSubmissionLimit(limit: desiredLimit, reason: "target \(targetFrameRate)fps")
    }

    nonisolated static func baselineDecodeSubmissionLimit(targetFrameRate: Int) -> Int {
        targetFrameRate > 60 ? 2 : 1
    }

    nonisolated static func baselineDecodeSubmissionLimit(
        targetFrameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        guard latencyMode != .lowestLatency else { return 1 }
        return baselineDecodeSubmissionLimit(targetFrameRate: targetFrameRate)
    }

    nonisolated static func maximumDecodeSubmissionLimit(
        targetFrameRate: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        guard latencyMode != .lowestLatency else { return 1 }
        return targetFrameRate > 60 ? 2 : 1
    }

    func setDecodeSubmissionLimit(limit: Int, reason: String? = nil) {
        let desiredLimit = min(max(1, limit), 2)
        guard desiredLimit != decodeSubmissionLimit else { return }
        decodeSubmissionLimit = desiredLimit
        drainDecodeSubmissionWaiters()
        if let reason {
            MirageLogger.decoder("Decode submission limit set to \(desiredLimit) (\(reason))")
        } else {
            MirageLogger.decoder("Decode submission limit set to \(desiredLimit)")
        }
    }

    func currentDecodeSubmissionLimit() -> Int {
        decodeSubmissionLimit
    }

    func currentInFlightDecodeSubmissions() -> Int {
        activeDecodeSubmissionLeases.count
    }

    func acquireDecodeSubmissionSlot() async -> DecodeSubmissionLease? {
        nextDecodeSubmissionLeaseID &+= 1
        let id = nextDecodeSubmissionLeaseID
        let generation = decodeSubmissionGeneration

        if activeDecodeSubmissionLeases.count < decodeSubmissionLimit, decodeSubmissionWaiters.isEmpty {
            return issueDecodeSubmissionLease(id: id, generation: generation)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                decodeSubmissionWaiters.append(DecodeSubmissionWaiter(
                    id: id,
                    generation: generation,
                    continuation: continuation
                ))
                drainDecodeSubmissionWaiters()
            }
        } onCancel: {
            Task { await self.cancelDecodeSubmissionWaiter(id: id, generation: generation) }
        }
    }

    func releaseDecodeSubmissionSlot(_ lease: DecodeSubmissionLease) {
        guard lease.generation == decodeSubmissionGeneration else { return }
        guard activeDecodeSubmissionLeases.remove(lease.id) != nil else { return }
        drainDecodeSubmissionWaiters()
    }

    func resetDecodeSubmissionSlots() {
        decodeSubmissionGeneration &+= 1
        activeDecodeSubmissionLeases.removeAll(keepingCapacity: true)
        let waiters = decodeSubmissionWaiters
        decodeSubmissionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func drainDecodeSubmissionWaiters() {
        while activeDecodeSubmissionLeases.count < decodeSubmissionLimit, !decodeSubmissionWaiters.isEmpty {
            let waiter = decodeSubmissionWaiters.removeFirst()
            guard waiter.generation == decodeSubmissionGeneration else {
                waiter.continuation.resume(returning: nil)
                continue
            }
            waiter.continuation.resume(returning: issueDecodeSubmissionLease(
                id: waiter.id,
                generation: waiter.generation
            ))
        }
    }

    private func issueDecodeSubmissionLease(id: UInt64, generation: UInt64) -> DecodeSubmissionLease {
        let lease = DecodeSubmissionLease(id: id, generation: generation)
        activeDecodeSubmissionLeases.insert(id)
        return lease
    }

    private func cancelDecodeSubmissionWaiter(id: UInt64, generation: UInt64) {
        guard let index = decodeSubmissionWaiters.firstIndex(where: { $0.id == id && $0.generation == generation }) else {
            return
        }
        let waiter = decodeSubmissionWaiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}
