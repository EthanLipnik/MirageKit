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
        let pFrameLatency = pFrameCompletionLatencyMetricsLocked(now: Date())
        return Metrics(
            droppedFrames: droppedFrameCount,
            pendingFrameCount: pendingFrames.count,
            pendingKeyframeCount: pendingKeyframeCountLocked(),
            pendingFrameBytes: pendingFrameBytesLocked(),
            frameBufferPoolRetainedBytes: bufferPool.retainedByteCount,
            budgetEvictions: memoryBudgetEvictionCount,
            incompleteFrameTimeouts: incompleteFrameTimeoutCount,
            incompleteFrameNoProgressTimeouts: incompleteFrameNoProgressTimeoutCount,
            incompleteFrameLifetimeTimeouts: incompleteFrameLifetimeTimeoutCount,
            missingFragmentTimeouts: missingFragmentTimeoutCount,
            forwardGapTimeouts: forwardGapTimeoutCount,
            pFrameCompletionLatencyP50Ms: pFrameLatency.p50,
            pFrameCompletionLatencyP95Ms: pFrameLatency.p95,
            pFrameCompletionLatencyMaxMs: pFrameLatency.max,
            latePFrameCompletionCount: pFrameLatency.lateCount,
            fecRecoveredFragmentCount: fecRecoveredFragmentCount
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
        return latestPendingKeyframeProgressLocked(now: CFAbsoluteTimeGetCurrent())
    }

    var keyframeWaitSnapshot: KeyframeWaitSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        return KeyframeWaitSnapshot(
            isAwaitingKeyframe: awaitingKeyframe,
            awaitingSince: awaitingKeyframeSince,
            latestPacketReceivedTime: lastPacketReceivedTime,
            latestPendingKeyframeProgress: latestPendingKeyframeProgressLocked(now: now),
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            pendingFrameCount: pendingFrames.count,
            pendingKeyframeCount: pendingKeyframeCountLocked(),
            incompleteFrameTimeouts: incompleteFrameTimeoutCount,
            incompleteFrameNoProgressTimeouts: incompleteFrameNoProgressTimeoutCount,
            incompleteFrameLifetimeTimeouts: incompleteFrameLifetimeTimeoutCount,
            forwardGapTimeouts: forwardGapTimeoutCount
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
            incompleteFrameNoProgressTimeoutCount = 0
            incompleteFrameLifetimeTimeoutCount = 0
            missingFragmentTimeoutCount = 0
            forwardGapTimeoutCount = 0
            fecRecoveredFragmentCount = 0
            pFrameCompletionLatencySamples.removeAll(keepingCapacity: false)
            lastPacketReceivedTime = 0
            startupKeyframeTimeoutOverrideEnabled = false
        }
        MirageLogger.log(.frameAssembly, "Reassembler reset for stream \(streamID)")
    }

    func pollTimeouts() {
        var shouldSignalFrameLoss = false
        var frameLossReason: FrameLossReason?
        var handler: FrameLossHandler?
        lock.lock()
        let timeoutResult = cleanupOldFramesLocked()
        if timeoutResult.shouldEnterAwaitingKeyframe {
            beginKeyframeWaitLocked()
            MirageLogger.log(
                .frameAssembly,
                "Entering keyframe wait after timeout poll: pFrame=\(timeoutResult.timedOutPFrames), " +
                    "keyframe=\(timeoutResult.timedOutKeyframes), " +
                    "incomplete=\(timeoutResult.incompleteFrameTimeouts), " +
                    "noProgress=\(timeoutResult.incompleteFrameNoProgressTimeouts), " +
                    "lifetime=\(timeoutResult.incompleteFrameLifetimeTimeouts), " +
                    "missingFragments=\(timeoutResult.missingFragmentTimeouts), " +
                    "forwardGap=\(timeoutResult.forwardGapTimeouts), " +
                    "anchor=\(hasDeliveredKeyframeAnchor)"
            )
        }
        if timeoutResult.timedOutPFrames + timeoutResult.timedOutKeyframes > 0 {
            shouldSignalFrameLoss = true
            frameLossReason = frameLossReason ?? timeoutResult.frameLossReason
        }
        if timeoutResult.missingExpectedPFrameGapTimedOut, !hasSignaledGapFrameLoss {
            shouldSignalFrameLoss = true
            hasSignaledGapFrameLoss = true
            frameLossReason = frameLossReason ?? .forwardGapTimeout
        }
        handler = onFrameLoss
        lock.unlock()

        if shouldSignalFrameLoss, let handler {
            handler(streamID: streamID, reason: frameLossReason ?? .timeout)
        }
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

    private func latestPendingKeyframeProgressLocked(now: CFAbsoluteTime) -> PendingKeyframeProgress? {
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
            age: max(0, now - frame.receivedAt.timeIntervalSinceReferenceDate)
        )
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

    func recordPFrameCompletionLatencyLocked(frame: PendingFrame, now: Date) {
        let latencyMs = max(0, frame.lastProgressAt.timeIntervalSince(frame.receivedAt) * 1000)
        pFrameCompletionLatencySamples.append(
            PFrameCompletionLatencySample(completedAt: now, latencyMs: latencyMs)
        )
        trimPFrameCompletionLatencySamplesLocked(now: now)
    }

    func pFrameCompletionLatencyMetricsLocked(
        now: Date
    ) -> (p50: Double, p95: Double, max: Double, lateCount: UInt64) {
        trimPFrameCompletionLatencySamplesLocked(now: now)
        guard !pFrameCompletionLatencySamples.isEmpty else {
            return (0, 0, 0, 0)
        }

        let latencies = pFrameCompletionLatencySamples
            .map(\.latencyMs)
            .sorted()
        let lateCount = UInt64(latencies.filter { $0 >= pFrameLateCompletionThresholdMs }.count)
        return (
            percentile(latencies, fraction: 0.50),
            percentile(latencies, fraction: 0.95),
            latencies.last ?? 0,
            lateCount
        )
    }

    private func trimPFrameCompletionLatencySamplesLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-pFrameCompletionLatencySampleWindow)
        while let first = pFrameCompletionLatencySamples.first,
              first.completedAt < cutoff {
            pFrameCompletionLatencySamples.removeFirst()
        }
    }

    private func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = min(
            sortedValues.count - 1,
            max(0, Int(ceil(Double(sortedValues.count) * fraction)) - 1)
        )
        return sortedValues[index]
    }
}
