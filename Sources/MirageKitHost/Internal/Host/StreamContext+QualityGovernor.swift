//
//  StreamContext+QualityGovernor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/17/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    private static let readabilityFloorRecoveryDirtyPercentage: Float = 6.0

    func currentStreamQualityContract() -> StreamQualityContract {
        StreamQualityContract(
            streamFamily: StreamQualityContract.family(for: streamKind),
            encodedWidth: Int(max(0, currentEncodedSize.width.rounded())),
            encodedHeight: Int(max(0, currentEncodedSize.height.rounded())),
            targetFrameRate: currentFrameRate,
            streamScale: Double(streamScale),
            codec: encoderConfig.codec,
            colorDepth: encoderConfig.colorDepth,
            enteredBitrateBps: enteredTargetBitrate,
            targetBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            maximumCeilingBps: bitrateAdaptationCeiling ?? requestedTargetBitrate ?? encoderConfig.bitrate,
            latencyMode: latencyMode,
            pathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            runtimeOwnership: runtimeQualityAdjustmentEnabled ? .host : .fixed,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            qualityCeiling: qualityCeiling,
            steadyQualityCeiling: steadyQualityCeiling,
            maxPayloadSize: maxPayloadSize,
            startupBaseTime: startupBaseTime,
            encodedFrameCount: encodedFrameCount
        )
    }

    func latestStreamQualityDecision() -> StreamQualityDecision {
        streamQualityGovernor.latestDecision
    }

    func allowsLocalMotionRuntimeReductionOverride(for reason: HostAdaptivePFrameController.Reason?) -> Bool {
        guard mediaPathProfile.usesLocalBulkTransportPolicy,
              encoderConfig.codec != .proRes4444,
              HostAdaptiveFrameCoordinator.pressureReasonIsMotionComplexity(reason?.rawValue) else {
            return false
        }
        return true
    }

    func adaptiveFrameDecisionQualityFloor(
        sourceStill: Bool,
        admitsStillQualityProbe: Bool
    ) -> Float {
        guard mediaPathProfile.usesLocalBulkTransportPolicy,
              !sourceStill,
              !admitsStillQualityProbe,
              encoderConfig.codec != .proRes4444 else {
            return qualityFloor
        }
        let motionFloor = currentStreamQualityContract().localMotionQualityFloor
        guard motionFloor > 0 else { return qualityFloor }
        return motionFloor
    }

    func adaptiveMotionBudgetQualityFloor(sourceStill: Bool) -> Float {
        guard mediaPathProfile.usesLocalBulkTransportPolicy,
              !sourceStill,
              encoderConfig.codec != .proRes4444 else {
            return qualityFloor
        }
        let motionFloor = currentStreamQualityContract().localMotionQualityFloor
        guard motionFloor > 0 else { return qualityFloor }
        return motionFloor
    }

    func adaptiveRuntimeQualityFloor(for decision: HostFrameBudgetDecision) -> Float {
        guard decision.state != .observing,
              encoderConfig.codec != .proRes4444 else {
            return 0
        }
        let contract = currentStreamQualityContract()
        if !mediaPathProfile.usesLocalBulkTransportPolicy {
            switch decision.reason {
            case .encoderLag:
                guard decision.state == .pressured || readabilityFloorRecoveryState.isProtecting else {
                    return 0
                }
                return contract.effectiveReadabilityQualityFloor
            case .startup,
                 .healthy,
                 .encodedFrame,
                 .motionOnset,
                 .pFrameLatency,
                 .transportBacklog,
                 .receiverFreshness,
                 .receiverBacklog,
                 .receiverLoss,
                 .senderDeadline,
                 .clientRecovery,
                 .adaptiveRepair:
                return 0
            }
        }
        if senderDeadlineRecoveryQualityCeiling != nil {
            return contract.localMotionQualityFloor
        }
        switch decision.reason {
        case .encodedFrame,
             .motionOnset,
             .senderDeadline:
            return contract.localMotionQualityFloor
        case .startup,
             .healthy,
             .pFrameLatency,
             .transportBacklog,
             .receiverFreshness,
             .receiverBacklog,
             .receiverLoss,
             .clientRecovery,
             .encoderLag,
             .adaptiveRepair:
            return contract.localReadabilityQualityFloor
        }
    }

    func updateReadabilityFloorRecoveryState(
        for decision: HostFrameBudgetDecision?,
        pressureSnapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        now: CFAbsoluteTime
    ) {
        guard let decision else {
            resetReadabilityFloorRecoveryStateIfNeeded(now: now)
            return
        }

        if let reason = readabilityFloorRecoveryReason(
            for: decision,
            pressureSnapshot: pressureSnapshot,
            now: now
        ) {
            let previousMode = readabilityFloorRecoveryState.mode
            let protectsFloor = readabilityFloorRecoveryState.update(reason: reason, now: now)
            if protectsFloor,
               previousMode != .floorProtecting {
                logReadabilityFloorRecoveryTransition(
                    mode: readabilityFloorRecoveryState.mode,
                    reason: reason,
                    now: now
                )
            }
            return
        }

        guard shouldHoldReadabilityFloorRecoveryState(
            through: decision,
            pressureSnapshot: pressureSnapshot,
            now: now
        ) else {
            resetReadabilityFloorRecoveryStateIfNeeded(now: now)
            return
        }
    }

    private func readabilityFloorRecoveryReason(
        for decision: HostFrameBudgetDecision,
        pressureSnapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        now: CFAbsoluteTime
    ) -> String? {
        guard runtimeQualityAdjustmentEnabled,
              encoderCatchUpQualityAdjustmentEnabled,
              encoderConfig.codec != .proRes4444,
              !mediaPathProfile.usesLocalBulkTransportPolicy,
              decision.reason == .encoderLag,
              decision.state == .severe else {
            return nil
        }

        guard currentStreamQualityContract().effectiveReadabilityQualityFloor > 0,
              readabilityFloorRecoveryEnvironmentAllows(pressureSnapshot: pressureSnapshot, now: now) else {
            return nil
        }

        return "still-severe-encoder-lag"
    }

    private func shouldHoldReadabilityFloorRecoveryState(
        through decision: HostFrameBudgetDecision,
        pressureSnapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        now: CFAbsoluteTime
    ) -> Bool {
        guard readabilityFloorRecoveryState.mode != .inactive,
              now - readabilityFloorRecoveryState.lastEligibleTime <= HostReadabilityFloorRecoveryState.emergencyGraceSeconds,
              readabilityFloorRecoveryEnvironmentAllows(pressureSnapshot: pressureSnapshot, now: now) else {
            return false
        }

        switch decision.reason {
        case .encoderLag,
             .encodedFrame:
            return decision.state != .observing
        case .startup,
             .healthy,
             .motionOnset,
             .pFrameLatency,
             .transportBacklog,
             .receiverFreshness,
             .receiverBacklog,
             .receiverLoss,
             .senderDeadline,
             .clientRecovery,
             .adaptiveRepair:
            return false
        }
    }

    private func readabilityFloorRecoveryEnvironmentAllows(
        pressureSnapshot: HostAdaptiveFrameCoordinator.TransportPressureSnapshot,
        now: CFAbsoluteTime
    ) -> Bool {
        let policy = activeFrameFreshnessPolicy
        guard !inputIsActive(now: now, policy: policy) else { return false }
        let latestFrameInfo = lastCapturedFrame?.info
        let lowMotion = sourceIsStill(now: now, policy: policy) ||
            latestFrameInfo?.isIdleFrame == true ||
            (latestFrameInfo?.dirtyPercentage ?? Float.greatestFiniteMagnitude) <= Self.readabilityFloorRecoveryDirtyPercentage
        guard lowMotion else { return false }

        guard !pressureSnapshot.startupProtectionActive,
              !pressureSnapshot.frameChainRepairActive,
              pressureSnapshot.receiverState != .severe,
              !pressureSnapshot.receiverLossHoldActive,
              !pressureSnapshot.senderDropHoldActive,
              pressureSnapshot.senderQueuedBytes < pressureSnapshot.queuePressureBytes,
              pressureSnapshot.unstartedPFrameCount <= 1,
              pressureSnapshot.oldestUnstartedPFrameLatenessMs <= runtimeQualityFrameBudgetMs() else {
            return false
        }

        return true
    }

    func resetReadabilityFloorRecoveryStateIfNeeded(now: CFAbsoluteTime) {
        guard readabilityFloorRecoveryState.mode != .inactive else { return }
        let previousMode = readabilityFloorRecoveryState.mode
        let previousReason = readabilityFloorRecoveryState.reason
        readabilityFloorRecoveryState.reset()
        logReadabilityFloorRecoveryTransition(
            mode: .inactive,
            reason: previousReason ?? previousMode.rawValue,
            now: now
        )
    }

    private func logReadabilityFloorRecoveryTransition(
        mode: HostReadabilityFloorRecoveryState.Mode,
        reason: String,
        now: CFAbsoluteTime
    ) {
        guard MirageLogger.isEnabled(.metrics),
              now - readabilityFloorRecoveryState.lastTransitionLogTime >= 0.5 else {
            return
        }
        readabilityFloorRecoveryState.lastTransitionLogTime = now
        MirageLogger.metrics(
            "event=readability_floor_recovery stream=\(streamID) " +
                "mode=\(mode.rawValue) reason=\(reason) " +
                "quality=\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "floor=\(qualityFloor.formatted(.number.precision(.fractionLength(2)))) " +
                "ceiling=\(qualityCeiling.formatted(.number.precision(.fractionLength(2))))"
        )
    }
}
#endif
