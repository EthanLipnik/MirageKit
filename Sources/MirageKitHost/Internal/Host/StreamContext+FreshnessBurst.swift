//
//  StreamContext+FreshnessBurst.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Freshness-first overload recovery for severe standard-mode transport pressure.
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
        let queueDepthText = latencyBurstCaptureQueueDepthOverride.map(String.init) ?? String(latencyBurstCaptureQueueDepth)

        freshnessBurstActive = true
        freshnessBurstEntryCount &+= 1

        MirageLogger.metrics(
            "Freshness burst enter for stream \(streamID): " +
                "reason=\(reason), queue=\(queuedKB)KB, bufferedFrames=\(bufferedFrames), queueDepth=\(queueDepthText)"
        )

        await enterLatencyBurst(now: now, reason: "freshness burst (\(reason))")
        freshnessBurstQueueResetCount &+= 1
        freshnessBurstRecoveryKeyframeCount &+= 1

        backpressureActive = true
        backpressureActiveSnapshot = true
        backpressureActivatedAt = now

        MirageLogger.metrics(
            "Freshness burst recovery keyframe queued for stream \(streamID): " +
                "reason=\(reason), queueReset=true, pendingKeyframe=\(pendingKeyframeReason ?? "none")"
        )
        return true
    }

    @discardableResult
    func exitFreshnessBurstIfNeeded(queueBytes: Int, reason: String) async -> Bool {
        guard freshnessBurstActive else { return false }
        guard queueBytes <= queuePressureBytes else { return false }

        let queuedKB = Int((Double(queueBytes) / 1024.0).rounded())
        let restoredQueueDepthText = preLatencyBurstCaptureQueueDepthOverride.map(String.init) ?? "auto"

        freshnessBurstActive = false
        clearBackpressureState(log: false)

        if !typingBurstActive {
            await exitLatencyBurst(now: CFAbsoluteTimeGetCurrent(), reason: "freshness burst (\(reason))")
        }

        MirageLogger.metrics(
            "Freshness burst exit for stream \(streamID): " +
                "reason=\(reason), queue=\(queuedKB)KB, typingBurstActive=\(typingBurstActive), restoredQueueDepth=\(restoredQueueDepthText)"
        )
        return true
    }

    @discardableResult
    func coalesceKeyframeRecoveryForFreshnessBurst(reason: String) -> Bool {
        guard freshnessBurstActive else { return false }

        freshnessBurstCoalescedKeyframeCount &+= 1
        noteLossEvent(
            reason: "Freshness burst keyframe coalesced (\(reason))",
            enablePFrameFEC: true
        )
        MirageLogger.metrics(
            "Freshness burst coalesced recovery keyframe for stream \(streamID): " +
                "reason=\(reason), count=\(freshnessBurstCoalescedKeyframeCount)"
        )
        return true
    }
}
#endif
