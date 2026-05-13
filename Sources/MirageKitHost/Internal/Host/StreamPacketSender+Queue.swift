//
//  StreamPacketSender+Queue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreFoundation
import MirageKit

#if os(macOS)

extension StreamPacketSender {
    /// Returns whether a non-keyframe missed its sender-local deadline.
    nonisolated func isExpiredNonKeyframe(_ item: WorkItem, now: CFAbsoluteTime) -> Bool {
        guard !item.isKeyframe, item.sendDeadline.isFinite else { return false }
        return now >= item.sendDeadline
    }

    /// Reduces the tracked queue byte count after a drop or send completes.
    nonisolated func reduceQueuedBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - bytes)
        }
    }

    /// Returns the queue accounting cost for a frame including FEC parity budget.
    nonisolated func accountedWireBytes(for item: WorkItem) -> Int {
        max(0, max(item.wireBytes, fecPayloadBudgetBytes(for: item)))
    }

    /// Drops expired queued non-keyframes while the caller holds `queueLock`.
    nonisolated func discardExpiredQueuedNonKeyframesLocked(now: CFAbsoluteTime) {
        guard !queuedWorkItems.isEmpty else { return }
        var retainedItems: [QueuedWorkItem] = []
        retainedItems.reserveCapacity(queuedWorkItems.count)
        for queuedItem in queuedWorkItems {
            if isExpiredNonKeyframe(queuedItem.item, now: now) {
                queuedBytes = max(0, queuedBytes - queuedItem.accountedBytes)
                queuedStalePacketDropCount &+= 1
                markDependencyFrameDroppedLocked(
                    queuedItem.item,
                    reason: .expiredQueuedFrame,
                    clientVisible: false
                )
            } else {
                retainedItems.append(queuedItem)
            }
        }
        queuedWorkItems = retainedItems
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

    /// Enforces realtime queue bounds by evicting stale non-keyframes first.
    nonisolated func enforceRealtimeQueueBoundsLocked(now: CFAbsoluteTime) {
        discardExpiredQueuedNonKeyframesLocked(now: now)
        while queuedWorkItems.count > Self.maxQueuedWorkItems || queuedBytes > Self.maxQueuedBytes {
            guard let evictionIndex = queuedWorkItems.firstIndex(where: { !$0.item.isKeyframe }) else { break }
            let evictedItem = queuedWorkItems.remove(at: evictionIndex)
            queuedBytes = max(0, queuedBytes - evictedItem.accountedBytes)
            queuedStalePacketDropCount &+= 1
            markDependencyFrameDroppedLocked(evictedItem.item, reason: .queueEviction, clientVisible: false)
        }
    }

    /// Updates dependency-drop state after a non-keyframe is dropped.
    nonisolated func markDependencyFrameDroppedLocked(
        _ item: WorkItem,
        reason: DependencyFrameDropReason,
        clientVisible: Bool
    ) {
        guard !item.isKeyframe else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if !clientVisible {
            queuedSenderLocalDeadlineDropCount &+= 1
            return
        }
        if now < dependencyDropSuppressionDeadline {
            resetKeyframeTrackingLocked()
            return
        }
        let wasAlreadyHolding = dropNonKeyframesUntilKeyframe && latestKeyframeGeneration == item.generation
        dropNonKeyframesUntilKeyframe = true
        latestKeyframeGeneration = item.generation
        latestKeyframeFrameNumber = max(latestKeyframeFrameNumber, item.frameNumber)
        guard !wasAlreadyHolding else { return }
        onDependencyFrameDropped?(item.streamID, item.frameNumber, reason)
    }

    /// Extends the grace window that keeps local keyframe-adjacent drops from becoming client visible.
    nonisolated func extendDependencyDropSuppressionLocked(
        now: CFAbsoluteTime,
        duration: CFAbsoluteTime = keyframeDependencyDropSuppressionSeconds
    ) {
        dependencyDropSuppressionDeadline = max(
            dependencyDropSuppressionDeadline,
            now + duration
        )
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
        latestKeyframeFrameNumber = 0
        latestKeyframeGeneration = 0
    }

    /// Clears queued work and dependency tracking while preserving lifecycle and telemetry counters.
    nonisolated func resetQueueStorageLocked() {
        queuedWorkItems.removeAll(keepingCapacity: true)
        queuedBytes = 0
        resetDependencyTrackingLocked()
    }

    /// Clears dependency-drop state while the caller holds `queueLock`.
    nonisolated func resetDependencyTrackingLocked() {
        dependencyDropSuppressionDeadline = 0
        resetKeyframeTrackingLocked()
    }
}

#endif
