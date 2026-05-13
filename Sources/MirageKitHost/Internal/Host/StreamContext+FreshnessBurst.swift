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

        backpressureActive = true
        backpressureActiveSnapshot = true
        backpressureActivatedAt = now

        MirageLogger.metrics(
            "Freshness burst local drain active for stream \(streamID): " +
                "reason=\(reason), queueReset=false, recoveryKeyframe=false"
        )
        return true
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
