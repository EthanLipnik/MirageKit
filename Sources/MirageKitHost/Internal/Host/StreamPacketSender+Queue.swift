//
//  StreamPacketSender+Queue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreFoundation

#if os(macOS)

extension StreamPacketSender {
    /// Reduces the tracked queue byte count after a drop or send completes.
    nonisolated func reduceQueuedBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - bytes)
        }
    }

    /// Returns the queue accounting cost for a frame including FEC parity budget.
    nonisolated func accountedWireBytes(for item: WorkItem) -> Int {
        return max(0, max(item.wireBytes, fecPayloadBudgetBytes(for: item)))
    }

    /// Returns the local lateness threshold for dependency-coded P-frames.
    nonisolated func hardSendDeadline(for item: WorkItem) -> CFAbsoluteTime {
        if let hardSendDeadline = item.hardSendDeadline {
            return hardSendDeadline
        }
        let frameInterval = 1.0 / Double(max(1, item.targetFrameRate))
        if item.deliveryMode == .lowMotionRamp {
            return item.sendDeadline + max(0.10, frameInterval * 6.0)
        }
        return item.sendDeadline + frameInterval * 2.0
    }

    /// Returns the P-frame lateness in milliseconds once it passes the local lateness threshold.
    nonisolated func nonKeyframeDeadlineLatenessMs(_ item: WorkItem, now: CFAbsoluteTime) -> Double? {
        guard !item.isKeyframe, item.sendDeadline.isFinite else { return nil }
        let deadline = hardSendDeadline(for: item)
        guard now > deadline else { return nil }
        return (now - deadline) * 1000
    }

    /// Records that a reserved P-frame is late but still being sent to preserve the dependency chain.
    @discardableResult
    func recordReservedPFrameLatenessIfNeeded(_ item: WorkItem, now: CFAbsoluteTime) -> Double? {
        guard let latenessMs = nonKeyframeDeadlineLatenessMs(item, now: now) else {
            if !item.isKeyframe { lateReservedPFrameStreak = 0 }
            return nil
        }
        lateReservedPFrameStreak += 1
        lateNonKeyframeSendCount &+= 1
        MirageLogger.stream(
            "event=reserved_p_frame_late_sent frame=\(item.frameNumber) stream=\(item.streamID) " +
                "latenessMs=\((latenessMs * 10).rounded() / 10) streak=\(lateReservedPFrameStreak) " +
                "wireBytes=\(item.wireBytes)"
        )
        return latenessMs
    }

    /// Returns whether an unstarted reserved P-frame is too stale to drain in Most Responsive mode.
    nonisolated func shouldAbandonReservedPFrameForFreshness(_ item: WorkItem, latenessMs: Double?) -> Bool {
        guard !item.isKeyframe,
              latenessMs != nil else {
            return false
        }
        if item.deliveryMode == .lowMotionRamp { return false }
        return lateReservedPFrameStreak >= 2
    }

    /// Current queue freshness snapshot used to avoid reserving a new stale P-frame behind old work.
    nonisolated func freshnessSnapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> FreshnessSnapshot {
        queueLock.withLock {
            freshnessSnapshotLocked(now: now)
        }
    }

    /// Builds a freshness snapshot while the caller holds `queueLock`.
    nonisolated func freshnessSnapshotLocked(now: CFAbsoluteTime) -> FreshnessSnapshot {
        var oldestAgeMs = 0.0
        var oldestLatenessMs = 0.0
        var unstartedPFrameCount = 0
        for queuedItem in queuedWorkItems where !queuedItem.item.isKeyframe {
            unstartedPFrameCount += 1
            let ageMs = max(0, (now - queuedItem.item.encodedAt) * 1000)
            oldestAgeMs = max(oldestAgeMs, ageMs)
            if let latenessMs = nonKeyframeDeadlineLatenessMs(queuedItem.item, now: now) {
                oldestLatenessMs = max(oldestLatenessMs, latenessMs)
            }
        }
        return FreshnessSnapshot(
            queuedBytes: queuedBytes,
            unstartedPFrameCount: unstartedPFrameCount,
            oldestUnstartedPFrameAgeMs: oldestAgeMs,
            oldestUnstartedPFrameLatenessMs: oldestLatenessMs,
            lateReservedPFrameStreak: lateReservedPFrameStreak
        )
    }

    /// Drops queued non-keyframes while preserving queued keyframes.
    nonisolated func discardQueuedNonKeyframesLocked(countAsHoldDrops: Bool) {
        guard !queuedWorkItems.isEmpty else { return }
        var retainedItems: [QueuedWorkItem] = []
        retainedItems.reserveCapacity(queuedWorkItems.count)
        for queuedItem in queuedWorkItems {
            if queuedItem.item.isKeyframe {
                retainedItems.append(queuedItem)
            } else {
                queuedBytes = max(0, queuedBytes - queuedItem.accountedBytes)
                if countAsHoldDrops {
                    queuedNonKeyframeHoldDropCount &+= 1
                } else {
                    queuedStalePacketDropCount &+= 1
                }
            }
        }
        queuedWorkItems = retainedItems
    }

    /// Removes older queued keyframes superseded by a newer keyframe in the same generation.
    nonisolated func discardSupersededQueuedKeyframesLocked(
        newestFrameNumber: UInt32,
        generation: UInt32
    ) {
        guard !queuedWorkItems.isEmpty else { return }
        var retainedItems: [QueuedWorkItem] = []
        retainedItems.reserveCapacity(queuedWorkItems.count)
        for queuedItem in queuedWorkItems {
            let queuedFrame = queuedItem.item
            let isSupersededKeyframe = queuedFrame.isKeyframe &&
                queuedFrame.generation == generation &&
                queuedFrame.frameNumber < newestFrameNumber
            if isSupersededKeyframe {
                queuedBytes = max(0, queuedBytes - queuedItem.accountedBytes)
                queuedStalePacketDropCount &+= 1
            } else {
                retainedItems.append(queuedItem)
            }
        }
        queuedWorkItems = retainedItems
    }

    /// Returns whether the requested keyframe is still queued.
    nonisolated func hasQueuedKeyframeLocked(frameNumber: UInt32, generation: UInt32) -> Bool {
        queuedWorkItems.contains {
            $0.item.isKeyframe &&
                $0.item.generation == generation &&
                $0.item.frameNumber == frameNumber
        }
    }

    /// Enforces realtime queue bounds by evicting non-keyframes first.
    nonisolated func enforceRealtimeQueueBoundsLocked() {
        while queuedWorkItems.count > Self.maxQueuedWorkItems || queuedBytes > Self.maxQueuedBytes {
            guard let evictionIndex = queuedWorkItems.firstIndex(where: { !$0.item.isKeyframe }) else { break }
            let evictedItem = queuedWorkItems.remove(at: evictionIndex)
            queuedBytes = max(0, queuedBytes - evictedItem.accountedBytes)
            queuedStalePacketDropCount &+= 1
            markDependencyFrameDroppedLocked(
                evictedItem.item,
                reason: .queueEviction
            )
        }
    }

    /// Enforces AWDL realtime display bounds before Loom admission can accumulate stale whole frames.
    nonisolated func enforceAwdlRealtimeQueueBoundsLocked() {
        while awdlRealtimeQueueIsOverBudgetLocked() {
            guard let evictionIndex = queuedWorkItems.firstIndex(where: {
                $0.item.usesAwdlRealtimeQueuePolicy && !$0.item.isKeyframe
            }) else {
                break
            }
            let evictedItem = queuedWorkItems.remove(at: evictionIndex)
            queuedBytes = max(0, queuedBytes - evictedItem.accountedBytes)
            queuedStalePacketDropCount &+= 1
            markDependencyFrameDroppedLocked(
                evictedItem.item,
                reason: .queueEviction
            )
        }
    }

    private nonisolated func awdlRealtimeQueueIsOverBudgetLocked() -> Bool {
        let awdlQueuedItems = queuedWorkItems.filter { $0.item.usesAwdlRealtimeQueuePolicy }
        let awdlQueuedNonKeyframes = awdlQueuedItems.filter { !$0.item.isKeyframe }.count
        return awdlQueuedItems.count > Self.maxAwdlQueuedWorkItems ||
            awdlQueuedNonKeyframes > Self.maxAwdlQueuedNonKeyframes ||
            queuedBytes > Self.maxAwdlQueuedBytes
    }

    /// Updates dependency-drop state after a non-keyframe is dropped.
    nonisolated func markDependencyFrameDroppedLocked(
        _ item: WorkItem,
        reason: DependencyFrameDropReason
    ) {
        guard !item.isKeyframe else { return }
        if dependencyBaselineKeyframeGeneration == item.generation,
           dependencyBaselineKeyframeFrameNumber >= item.frameNumber {
            return
        }

        let wasAlreadyHolding = dependencyRecoveryRequiresKeyframe &&
            latestDependencyDropGeneration == item.generation
        dropNonKeyframesUntilKeyframe = true
        dependencyRecoveryRequiresKeyframe = true
        latestDependencyDropGeneration = item.generation
        latestDependencyDropFrameNumber = max(latestDependencyDropFrameNumber, item.frameNumber)
        discardQueuedNonKeyframesLocked(countAsHoldDrops: true)
        guard !wasAlreadyHolding else { return }
        onDependencyFrameDropped?(item.streamID, item.frameNumber, reason)
    }

    /// Records the newest keyframe that can cover dependency drops at or before its frame number.
    nonisolated func recordDependencyBaselineKeyframeLocked(_ item: WorkItem) {
        guard item.isKeyframe else { return }
        if dependencyBaselineKeyframeGeneration != item.generation ||
            item.frameNumber >= dependencyBaselineKeyframeFrameNumber {
            dependencyBaselineKeyframeGeneration = item.generation
            dependencyBaselineKeyframeFrameNumber = item.frameNumber
        }
    }

    /// Returns whether a keyframe is new enough to cover any currently held dependency drop.
    nonisolated func keyframeSatisfiesDependencyRecoveryLocked(_ item: WorkItem) -> Bool {
        guard dependencyRecoveryRequiresKeyframe else { return true }
        guard latestDependencyDropGeneration == item.generation else { return false }
        return item.frameNumber >= latestDependencyDropFrameNumber
    }

    /// Returns whether the sender is holding P-frames until a new keyframe covers a dropped dependency.
    func requiresDependencyRecoveryKeyframe() -> Bool {
        queueLock.withLock {
            dependencyRecoveryRequiresKeyframe
        }
    }

    /// Returns the worst-case payload budget for a frame including FEC parity payloads.
    nonisolated func fecPayloadBudgetBytes(for item: WorkItem) -> Int {
        let maxPayload = max(1, maxPayloadSize)
        let frameByteCount = max(0, item.frameByteCount)
        let dataFragments = frameByteCount > 0 ? (frameByteCount + maxPayload - 1) / maxPayload : 0
        let blockSize = max(0, item.fecBlockSize)
        let parityFragments = blockSize > 1 ? (dataFragments + blockSize - 1) / blockSize : 0
        return frameByteCount + parityFragments * maxPayload
    }

    /// Clears keyframe dependency tracking while the caller holds `queueLock`.
    nonisolated func resetKeyframeTrackingLocked() {
        dropNonKeyframesUntilKeyframe = false
        dependencyRecoveryRequiresKeyframe = false
        latestKeyframeFrameNumber = 0
        latestKeyframeGeneration = 0
        latestDependencyDropFrameNumber = 0
        latestDependencyDropGeneration = 0
        lateReservedPFrameStreak = 0
    }

    /// Clears queued work and dependency tracking while preserving lifecycle and telemetry counters.
    nonisolated func resetQueueStorageLocked() {
        queuedWorkItems.removeAll(keepingCapacity: true)
        queuedBytes = 0
        resetDependencyTrackingLocked()
    }

    /// Clears dependency-drop state while the caller holds `queueLock`.
    nonisolated func resetDependencyTrackingLocked() {
        dependencyBaselineKeyframeFrameNumber = 0
        dependencyBaselineKeyframeGeneration = 0
        resetKeyframeTrackingLocked()
    }
}

#endif
