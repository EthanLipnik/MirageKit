//
//  MirageReceiverHealthController+Policy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Receiver health policy thresholds and bitrate step constants.
//

import Foundation

extension MirageReceiverHealthController {
    static let minimumBitrateBps = 12_000_000
    static let severeBackoffStep = 0.85
    static let normalBackoffStep = 0.90
    static let receiverMediaFirstBackoffStep = 0.85
    static let receiverMediaRepeatedBackoffStep = 0.75
    static let receiverMediaFailureWindowSeconds: CFAbsoluteTime = 10
    static let receiverMediaBackoffCooldownSeconds: CFAbsoluteTime = 10
    static let backoffCooldownSeconds: CFAbsoluteTime = 10
    static let recoveryHealthySampleThreshold = 5
    static let severeStressSampleThreshold = 2
    static let normalStressSampleThreshold = 3
    static let probeHealthySampleThreshold = 4
    static let fastStartProbeHealthySampleThreshold = 2
    static let pendingProbeHealthySampleThreshold = 2
    static let pendingProbeTimeoutSeconds: CFAbsoluteTime = 12
    static let normalProbeIncreaseFloorBps = 6_000_000
    static let normalProbeIncreasePercent = 115
    static let normalProbeIncreaseMaximumStepBps = 24_000_000
    static let fastStartProbeIncreaseFloorBps = 12_000_000
    static let fastStartProbeIncreasePercent = 120
    static let fastStartProbeIncreaseMaximumStepBps = 32_000_000
    static let successfulProbeCooldownSeconds: CFAbsoluteTime = 8
    static let failedProbeCooldownSeconds: CFAbsoluteTime = 12
    static let probeSuppressionCooldownSeconds: CFAbsoluteTime = 3
    static let fastStartSuccessfulProbeCooldownSeconds: CFAbsoluteTime = 4
    static let fastStartFailedProbeCooldownSeconds: CFAbsoluteTime = 8
    static let fastStartDurationSeconds: CFAbsoluteTime = 12
    static let normalBackoffPromotionCeilingStep = 0.95
    static let severeBackoffPromotionCeilingStep = 0.90
    static let ceilingRecoveryHealthySamples = 12
    static let dynamicRouteCeilingRecoveryHealthySamples = 8
    static let promotionCeilingRecoveryFloorBps = 3_000_000
    static let promotionCeilingRecoveryPercent = 105
    static let promotionCeilingRecoveryMaximumStepBps = 12_000_000
    static let sendQueueStressBytes = 800_000
    static let sendQueueSevereBytes = 2_000_000
    static let sendStartDelayStressMs = 4.0
    static let sendStartDelaySevereMs = 8.0
    static let sendCompletionStressMs = 18.0
    static let sendCompletionSevereMs = 32.0
    static let packetPacerStressMs = 0.75
    static let packetPacerSevereMs = 2.0
    static let transportDropStressCount: UInt64 = 4
    static let transportDropSevereCount: UInt64 = 24
    static let clientFragmentLossFrameStressCount: UInt64 = 2
    static let clientFragmentLossFrameSevereCount: UInt64 = 8
    static let clientForwardGapTimeoutSevereCount: UInt64 = 2
    static let clientMissingFragmentStressCount: UInt64 = 32
    static let clientMissingFragmentSevereCount: UInt64 = 128
    static let clientPFrameLatencyStressMs = 250.0
    static let clientPFrameLatencySevereMs = 450.0
    static let clientLatePFrameStressCount: UInt64 = 2
}
