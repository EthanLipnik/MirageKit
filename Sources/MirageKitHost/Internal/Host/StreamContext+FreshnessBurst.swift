//
//  StreamContext+FreshnessBurst.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Freshness-first local backlog shedding for severe standard-mode send pressure.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func enterFreshnessBurstIfNeeded(queueBytes: Int, reason: String) async -> Bool {
        guard !freshnessBurstActive else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        let queuedKB = Self.roundedKilobytes(queueBytes)
        let bufferedFrames = frameInbox.pendingCount
        freshnessBurstActive = true
        freshnessBurstEntryCount &+= 1

        MirageLogger.metrics(
            "Freshness burst enter for stream \(streamID): " +
                "reason=\(reason), queue=\(queuedKB)KB, bufferedFrames=\(bufferedFrames)"
        )

        await enterLatencyBurst(reason: "freshness burst (\(reason))")
        let recoveryResult = await enterAwdlFreshnessRecoveryIfNeeded(reason: reason)

        backpressureActive = true
        backpressureActiveSnapshot = true
        backpressureActivatedAt = now

        MirageLogger.metrics(
            "Freshness burst local drain active for stream \(streamID): " +
                "reason=\(reason), queueReset=\(recoveryResult.queueReset), " +
                "recoveryKeyframe=\(recoveryResult.recoveryKeyframe)"
        )
        return true
    }

    private func enterAwdlFreshnessRecoveryIfNeeded(reason: String) async -> (
        queueReset: Bool,
        recoveryKeyframe: Bool
    ) {
        guard transportPathKind == .awdl else {
            return (queueReset: false, recoveryKeyframe: false)
        }

        let resetResult = await packetSender?.resetQueueForFreshnessRecovery(reason: reason)
        suppressEncodedNonKeyframesUntilKeyframe = true
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0

        let recoveryReason = "AWDL freshness burst"
        let queued = queueKeyframe(
            reason: recoveryReason,
            checkInFlight: false,
            requiresFlush: true,
            requiresReset: false,
            urgent: true,
            countsAgainstRecoveryBudget: false
        )
        if queued {
            noteLossEvent(reason: recoveryReason, enablePFrameFEC: true)
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }

        let droppedItems = resetResult?.droppedItemCount ?? 0
        let droppedKB = Self.roundedKilobytes(resetResult?.droppedBytes ?? 0)
        MirageLogger.metrics(
            "AWDL freshness recovery for stream \(streamID): " +
                "reason=\(reason), queuedKeyframe=\(queued), droppedItems=\(droppedItems), " +
                "droppedQueue=\(droppedKB)KB"
        )
        return (queueReset: resetResult != nil, recoveryKeyframe: queued)
    }

    var usesSoftSenderDelaySmoothing: Bool {
        latencyMode == .smoothest
    }

    func enterSoftFreshnessDrainIfNeeded(frameBudgetMs: Double, reason: String) {
        guard usesSoftSenderDelaySmoothing else { return }
        guard !freshnessBurstActive, !latencyBurstActive else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let clearedBacklog = frameInbox.clear()
        if clearedBacklog > 0 {
            let droppedCount = UInt64(clearedBacklog)
            captureDroppedIntervalCount += droppedCount
            droppedFrameCount += droppedCount
        }

        softFreshnessDrainActive = true
        softFreshnessDrainDeadline = now + max(0.12, min(0.35, frameBudgetMs * 3.0 / 1000.0))
        qualityRaiseSuppressionUntil = max(qualityRaiseSuppressionUntil, now + qualityRaisePostSpikeCooldown)
        softFreshnessDrainCount &+= 1
        latencyBurstDrainsNewestFrames = true
        scheduleProcessingIfNeeded()

        MirageLogger.metrics(
            "Soft freshness drain enter for stream \(streamID): " +
                "reason=\(reason), clearedFrames=\(clearedBacklog), count=\(softFreshnessDrainCount)"
        )
    }

    func expireSoftFreshnessDrainIfNeeded(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard softFreshnessDrainActive else { return }
        guard !freshnessBurstActive, !latencyBurstActive else { return }
        guard now >= softFreshnessDrainDeadline else { return }

        softFreshnessDrainActive = false
        softFreshnessDrainDeadline = 0
        latencyBurstDrainsNewestFrames = false
        MirageLogger.metrics("Soft freshness drain exit for stream \(streamID)")
    }

    func exitFreshnessBurstIfNeeded(queueBytes: Int, reason: String) async -> Bool {
        guard freshnessBurstActive else { return false }
        guard queueBytes <= queuePressureBytes else { return false }

        let queuedKB = Self.roundedKilobytes(queueBytes)
        let restoredQueueDepthText = preLatencyBurstCaptureQueueDepthOverride.map(String.init) ?? "default"

        freshnessBurstActive = false
        clearBackpressureState(log: false)

        await exitLatencyBurst(now: CFAbsoluteTimeGetCurrent(), reason: "freshness burst (\(reason))")

        MirageLogger.metrics(
            "Freshness burst exit for stream \(streamID): " +
                "reason=\(reason), queue=\(queuedKB)KB, restoredQueueDepth=\(restoredQueueDepthText)"
        )
        return true
    }

    func logFreshnessBurstKeyframeRecovery(reason: String) {
        guard freshnessBurstActive else { return }

        MirageLogger.metrics(
            "Freshness burst allowing explicit recovery keyframe for stream \(streamID): reason=\(reason)"
        )
    }
}
#endif
