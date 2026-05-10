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
    struct FreshnessBurstSnapshot: Sendable, Equatable {
        let isActive: Bool
        let latencyBurstActive: Bool
        let captureQueueDepthOverride: Int?
        let newestFrameDrainEnabled: Bool
        let activeQuality: Float
        let qualityCeiling: Float
        let bitrate: Int?
        let requestedTargetBitrate: Int?
        let entryCount: UInt64
        let queueResetCount: UInt64
        let recoveryKeyframeCount: UInt64
        let coalescedRecoveryKeyframeCount: UInt64
    }

    func freshnessBurstSnapshot() -> FreshnessBurstSnapshot {
        FreshnessBurstSnapshot(
            isActive: freshnessBurstActive,
            latencyBurstActive: latencyBurstActive,
            captureQueueDepthOverride: latencyBurstCaptureQueueDepthOverride,
            newestFrameDrainEnabled: latencyBurstDrainsNewestFrames,
            activeQuality: activeQuality,
            qualityCeiling: qualityCeiling,
            bitrate: encoderConfig.bitrate,
            requestedTargetBitrate: requestedTargetBitrate,
            entryCount: freshnessBurstEntryCount,
            queueResetCount: freshnessBurstQueueResetCount,
            recoveryKeyframeCount: freshnessBurstRecoveryKeyframeCount,
            coalescedRecoveryKeyframeCount: freshnessBurstCoalescedKeyframeCount
        )
    }

    @discardableResult
    func enterFreshnessBurstIfNeeded(queueBytes: Int, reason: String) async -> Bool {
        guard !freshnessBurstActive else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        let queuedKB = Int((Double(queueBytes) / 1024.0).rounded())
        let bufferedFrames = frameInbox.pendingCount()
        freshnessBurstActive = true
        freshnessBurstEntryCount &+= 1

        MirageLogger.metrics(
            "Freshness burst enter for stream \(streamID): " +
                "reason=\(reason), queue=\(queuedKB)KB, bufferedFrames=\(bufferedFrames)"
        )

        await enterLatencyBurst(now: now, reason: "freshness burst (\(reason))")

        backpressureActive = true
        backpressureActiveSnapshot = true
        backpressureActivatedAt = now

        MirageLogger.metrics(
            "Freshness burst local drain active for stream \(streamID): " +
                "reason=\(reason), queueReset=false, recoveryKeyframe=false"
        )
        return true
    }

    @discardableResult
    func applySmoothestSenderPressureRelief(reason: String) async -> Bool {
        guard latencyMode == .smoothest else { return false }
        guard !freshnessBurstActive, !latencyBurstActive else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            now + qualityRaisePostSpikeCooldown
        )
        qualityCeiling = resolvedQualityCeiling()
        if activeQuality > qualityCeiling {
            activeQuality = qualityCeiling
        }

        let keyframeCeiling = min(encoderConfig.keyframeQuality, qualityCeiling)
        let nextQuality = max(
            qualityFloor,
            min(activeQuality - qualityDropStep, keyframeCeiling - qualityDropStep)
        )
        qualityOverBudgetCount = 0
        qualityUnderBudgetCount = 0
        guard nextQuality < activeQuality else {
            MirageLogger.metrics(
                "Smoothest sender pressure relief held for stream \(streamID): " +
                    "reason=\(reason), quality=\(activeQuality)"
            )
            return false
        }

        activeQuality = nextQuality
        lastQualityAdjustmentTime = now
        await encoder?.updateQuality(activeQuality)

        let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.metrics(
            "Smoothest sender pressure quality down to \(qualityText) for stream \(streamID): reason=\(reason)"
        )
        return true
    }

    @discardableResult
    func exitFreshnessBurstIfNeeded(queueBytes: Int, reason: String) async -> Bool {
        guard freshnessBurstActive else { return false }
        guard queueBytes <= queuePressureBytes else { return false }

        let queuedKB = Int((Double(queueBytes) / 1024.0).rounded())
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

    @discardableResult
    func coalesceKeyframeRecoveryForFreshnessBurst(reason: String) -> Bool {
        guard freshnessBurstActive else { return false }

        MirageLogger.metrics(
            "Freshness burst allowing explicit recovery keyframe for stream \(streamID): reason=\(reason)"
        )
        return false
    }
}
#endif
