//
//  FrameReassembler+MemoryBudget.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

extension FrameReassembler {
    func enforceMemoryBudgetLocked() -> UInt64 {
        var evictedCount: UInt64 = 0

        func evict(_ frameNumber: UInt32) {
            guard let frame = pendingFrames.removeValue(forKey: frameNumber) else { return }
            frame.buffer.release()
            droppedFrameCount += 1
            memoryBudgetEvictionCount += 1
            evictedCount += 1
        }

        while pendingFrames.count > memoryBudget.maxPendingFrames,
              let frameNumber = memoryBudgetEvictionCandidateLocked() {
            evict(frameNumber)
        }

        while pendingKeyframeCountLocked() > memoryBudget.maxPendingKeyframes,
              let frameNumber = oldestPendingKeyframeLocked(excluding: bestPendingKeyframeNumberLocked()) {
            evict(frameNumber)
        }

        while pendingFrameBytesLocked() > memoryBudget.maxPendingBytes,
              pendingFrames.count > 1,
              let frameNumber = memoryBudgetEvictionCandidateLocked() {
            evict(frameNumber)
        }

        if evictedCount > 0 {
            enterKeyframeOnlyModeLocked()
            MirageLogger.client(
                "Frame reassembler memory budget evicted \(evictedCount) pending frame(s) for stream \(streamID); " +
                    "pendingBytes=\(pendingFrameBytesLocked()), pendingFrames=\(pendingFrames.count)"
            )
        }

        return evictedCount
    }

    func bestPendingKeyframeNumberLocked() -> UInt32? {
        let mostProgressed = pendingFrames
            .filter(\.value.isKeyframe)
            .max { lhs, rhs in
                let lhsProgress = keyframeProgressRatioLocked(lhs.value)
                let rhsProgress = keyframeProgressRatioLocked(rhs.value)
                if lhsProgress != rhsProgress {
                    return lhsProgress < rhsProgress
                }
                if lhs.value.lastProgressAt != rhs.value.lastProgressAt {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
        if let mostProgressed,
           let frame = pendingFrames[mostProgressed],
           keyframeProgressRatioLocked(frame) >= pendingKeyframeProgressPreservationThreshold {
            return mostProgressed
        }
        if let newest = newestPendingKeyframeNumberLocked(),
           let newestFrame = pendingFrames[newest],
           newestFrame.retainedMemoryBytes <= memoryBudget.maxPendingBytes {
            return newest
        }
        return mostProgressed
    }

    func pendingFrameBytesLocked() -> Int {
        pendingFrames.values.reduce(0) { $0 + $1.retainedMemoryBytes }
    }

    func pendingKeyframeCountLocked() -> Int {
        pendingFrames.values.reduce(0) { $0 + ($1.isKeyframe ? 1 : 0) }
    }

    private func memoryBudgetEvictionCandidateLocked() -> UInt32? {
        if let nonKeyframe = oldestPendingFrameNumberLocked(where: { entry in
            !entry.value.isKeyframe
        }) {
            return nonKeyframe
        }
        return oldestPendingKeyframeLocked(excluding: bestPendingKeyframeNumberLocked())
    }

    private func oldestPendingKeyframeLocked(excluding excludedFrameNumber: UInt32?) -> UInt32? {
        oldestPendingFrameNumberLocked { frameNumber, frame in
            frame.isKeyframe && frameNumber != excludedFrameNumber
        }
    }

    private func newestPendingKeyframeNumberLocked() -> UInt32? {
        pendingFrames
            .filter(\.value.isKeyframe)
            .max { lhs, rhs in
                if lhs.value.lastProgressAt != rhs.value.lastProgressAt {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
    }

    private func keyframeProgressRatioLocked(_ frame: PendingFrame) -> Double {
        guard frame.dataFragmentCount > 0 else { return 0 }
        return Double(frame.receivedCount) / Double(frame.dataFragmentCount)
    }

    private func oldestPendingFrameNumberLocked(
        where shouldInclude: ((key: UInt32, value: PendingFrame)) -> Bool
    )
    -> UInt32? {
        pendingFrames
            .filter(shouldInclude)
            .min { lhs, rhs in
                if lhs.value.receivedAt != rhs.value.receivedAt {
                    return lhs.value.receivedAt < rhs.value.receivedAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .key
    }
}
