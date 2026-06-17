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
              mediaPathProfile.usesLocalBulkTransportPolicy,
              encoderConfig.codec != .proRes4444 else {
            return 0
        }
        let contract = currentStreamQualityContract()
        switch decision.reason {
        case .encodedFrame,
             .motionOnset:
            return contract.localMotionQualityFloor
        case .startup,
             .healthy,
             .pFrameLatency,
             .transportBacklog,
             .receiverFreshness,
             .receiverBacklog,
             .receiverLoss,
             .clientRecovery,
             .senderDeadline,
             .encoderLag,
             .adaptiveRepair:
            return contract.localReadabilityQualityFloor
        }
    }
}
#endif
