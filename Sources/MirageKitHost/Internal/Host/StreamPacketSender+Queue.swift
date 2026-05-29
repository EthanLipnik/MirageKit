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
    /// Reduces the tracked queue byte count after a drop or send completes.
    nonisolated func reduceQueuedBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        queueLock.withLock {
            queuedBytes = max(0, queuedBytes - bytes)
        }
    }

    /// Returns the queue accounting cost for a frame including FEC parity budget.
    nonisolated func accountedWireBytes(for item: WorkItem) -> Int {
        if videoTransportMode.usesReliableOrderedDelivery {
            return max(0, item.frameByteCount)
        }
        return max(0, max(item.wireBytes, fecPayloadBudgetBytes(for: item)))
    }

    /// Returns whether an unreliable non-keyframe missed its sender-local deadline.
    nonisolated func isExpiredNonKeyframe(_ item: WorkItem, now: CFAbsoluteTime) -> Bool {
        guard !videoTransportMode.usesReliableOrderedDelivery else { return false }
        guard !item.isKeyframe, item.sendDeadline.isFinite else { return false }
        return now >= hardSendDeadline(for: item)
    }

    /// Returns the hard abandon deadline for dependency-coded P-frames.
    nonisolated func hardSendDeadline(for item: WorkItem) -> CFAbsoluteTime {
        let frameInterval = 1.0 / Double(max(1, item.targetFrameRate))
        return item.sendDeadline + frameInterval * 2.0
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
                    reason: .expiredQueuedFrame
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

    /// Enforces realtime queue bounds by evicting non-keyframes first.
    nonisolated func enforceRealtimeQueueBoundsLocked(now: CFAbsoluteTime) {
        discardExpiredQueuedNonKeyframesLocked(now: now)
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

    /// Gives reliable ordered video room to ride out local bursts before declaring dependency loss.
    nonisolated func enforceReliableQueueBoundsLocked() {
        while queuedWorkItems.count > Self.maxReliableQueuedWorkItems ||
            queuedBytes > Self.maxReliableQueuedBytes {
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

    /// Updates dependency-drop state after a non-keyframe is dropped.
    nonisolated func markDependencyFrameDroppedLocked(
        _ item: WorkItem,
        reason: DependencyFrameDropReason
    ) {
        guard !item.isKeyframe else { return }
        switch reason {
        case .expiredBeforeEnqueue,
             .expiredBeforeSend,
             .expiredQueuedFrame:
            queuedSenderLocalDeadlineDropCount &+= 1
        case .generationAbort,
             .oversizedFrame,
             .queueEviction:
            break
        }

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
