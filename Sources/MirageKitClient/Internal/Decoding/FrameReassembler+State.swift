//
//  FrameReassembler+State.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Frame reassembler state snapshots, trims, and reset helpers.
//

import CoreFoundation
import MirageKit

extension FrameReassembler {
    var hasReceivedPackets: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalPacketsReceived > 0
    }

    var snapshotMetrics: Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(
            droppedFrames: droppedFrameCount,
            pendingFrameCount: pendingFrames.count,
            pendingKeyframeCount: pendingKeyframeCountLocked(),
            pendingFrameBytes: pendingFrameBytesLocked(),
            frameBufferPoolRetainedBytes: bufferPool.retainedByteCount,
            budgetEvictions: memoryBudgetEvictionCount,
            incompleteFrameTimeouts: incompleteFrameTimeoutCount,
            missingFragmentTimeouts: missingFragmentTimeoutCount
        )
    }

    func trimForMemoryPressure() -> MemoryTrimResult {
        let result: MemoryTrimResult
        let evictedFrames: Int
        let releasedPendingBytes: Int
        let purgedRetainedBytes: Int
        lock.lock()
        do {
            defer { lock.unlock() }
            evictedFrames = pendingFrames.count
            releasedPendingBytes = pendingFrameBytesLocked()
            for frame in pendingFrames.values {
                frame.buffer.release()
            }
            pendingFrames.removeAll(keepingCapacity: false)
            if evictedFrames > 0 {
                droppedFrameCount += UInt64(evictedFrames)
                beginAwaitingKeyframe()
            }
            purgedRetainedBytes = bufferPool.purgeRetainedBuffers()
            result = MemoryTrimResult(
                evictedFrames: evictedFrames,
                releasedPendingBytes: releasedPendingBytes,
                purgedRetainedBytes: purgedRetainedBytes
            )
        }

        if evictedFrames > 0 || purgedRetainedBytes > 0 {
            MirageLogger.client(
                "Memory pressure trimmed \(evictedFrames) reassembler frame(s) for stream \(streamID); " +
                    "releasedPendingBytes=\(releasedPendingBytes), purgedRetainedBytes=\(purgedRetainedBytes)"
            )
        }

        return result
    }

    func trimPendingFramesForRecovery(reason: String) {
        let evictedFrames: Int
        let releasedPendingBytes: Int
        lock.lock()
        do {
            defer { lock.unlock() }
            evictedFrames = pendingFrames.count
            releasedPendingBytes = pendingFrameBytesLocked()
            for frame in pendingFrames.values {
                frame.buffer.release()
            }
            pendingFrames.removeAll(keepingCapacity: false)
            if evictedFrames > 0 {
                droppedFrameCount += UInt64(evictedFrames)
            }
            beginAwaitingKeyframe()
        }

        if evictedFrames > 0 {
            MirageLogger.client(
                "Recovery trimmed \(evictedFrames) reassembler frame(s) for stream \(streamID); " +
                    "reason=\(reason), releasedPendingBytes=\(releasedPendingBytes)"
            )
        }
    }

    func beginKeyframeWait() {
        lock.lock()
        do {
            defer { lock.unlock() }
            beginKeyframeWaitLocked()
        }
        MirageLogger.log(.frameAssembly, "Entering keyframe wait for stream \(streamID)")
    }

    func setStartupKeyframeTimeoutOverrideEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        startupKeyframeTimeoutOverrideEnabled = enabled
    }

    var latestPacketReceivedTime: CFAbsoluteTime {
        lock.lock()
        defer { lock.unlock() }
        return lastPacketReceivedTime
    }

    var isAwaitingKeyframe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return awaitingKeyframe
    }

    var latestPendingKeyframeProgress: PendingKeyframeProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard let frameNumber = bestPendingKeyframeNumberLocked(),
              let frame = pendingFrames[frameNumber] else {
            return nil
        }
        let lastProgressTime = frame.lastProgressAt.timeIntervalSinceReferenceDate
        let dataFragments = max(1, frame.dataFragmentCount)
        let progressRatio = min(1.0, Double(frame.receivedCount) / Double(dataFragments))
        return PendingKeyframeProgress(
            frameNumber: frameNumber,
            epoch: frame.epoch,
            dimensionToken: frame.dimensionToken,
            receivedFragments: frame.receivedCount,
            dataFragments: frame.dataFragmentCount,
            progressRatio: progressRatio,
            receivedBytes: min(frame.expectedTotalBytes, frame.receivedCount * maxPayloadSize),
            expectedBytes: frame.expectedTotalBytes,
            lastProgressTime: lastProgressTime,
            age: max(0, CFAbsoluteTimeGetCurrent() - frame.receivedAt.timeIntervalSinceReferenceDate)
        )
    }

    var hasKeyframeAnchor: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasDeliveredKeyframeAnchor
    }

    func reset() {
        lock.lock()
        do {
            defer { lock.unlock() }
            for frame in pendingFrames.values {
                frame.buffer.release()
            }
            pendingFrames.removeAll()
            lastCompletedFrame = 0
            lastDeliveredKeyframe = 0
            hasDeliveredKeyframeAnchor = false
            hasSignaledGapFrameLoss = false
            clearAwaitingKeyframe()
            droppedFrameCount = 0
            memoryBudgetEvictionCount = 0
            incompleteFrameTimeoutCount = 0
            missingFragmentTimeoutCount = 0
            lastPacketReceivedTime = 0
            startupKeyframeTimeoutOverrideEnabled = false
        }
        MirageLogger.log(.frameAssembly, "Reassembler reset for stream \(streamID)")
    }

    func beginAwaitingKeyframe() {
        if !awaitingKeyframe || awaitingKeyframeSince == 0 {
            awaitingKeyframe = true
            awaitingKeyframeSince = CFAbsoluteTimeGetCurrent()
        }
    }

    func clearAwaitingKeyframe() {
        awaitingKeyframe = false
        awaitingKeyframeSince = 0
    }

    func isStaleKeyframeLocked(_ frameNumber: UInt32) -> Bool {
        guard hasDeliveredKeyframeAnchor else { return false }
        if frameNumber == lastDeliveredKeyframe { return true }
        guard frameNumber < lastDeliveredKeyframe else { return false }
        return lastDeliveredKeyframe - frameNumber <= 1000
    }

    func purgeStaleKeyframesLocked() {
        guard hasDeliveredKeyframeAnchor else { return }
        let staleFrames = pendingFrames.filter { entry in
            entry.value.isKeyframe && isStaleKeyframeLocked(entry.key)
        }
        for (frameNumber, frame) in staleFrames {
            pendingFrames.removeValue(forKey: frameNumber)
            frame.buffer.release()
            droppedFrameCount += 1
        }
    }
}
