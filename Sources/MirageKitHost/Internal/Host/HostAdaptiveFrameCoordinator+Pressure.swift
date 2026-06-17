//
//  HostAdaptiveFrameCoordinator+Pressure.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/16/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension HostAdaptiveFrameCoordinator {
    struct TransportPressureSnapshot: Sendable, Equatable {
        let mediaPathProfile: MirageMediaPathProfile
        let currentFrameRate: Int
        let receiverState: ReceiverEvidenceState
        let receiverCapacityLearningQuarantineReason: String?
        let receiverReassemblyBacklogFrames: Int
        let receiverReassemblyBacklogBytes: Int
        let receiverDecodeBacklogFrames: Int
        let receiverPresentationBacklogFrames: Int
        let receiverLossHoldActive: Bool
        let receiverAckLagMs: Double?
        let senderQueuedBytes: Int
        let queuePressureBytes: Int
        let maxQueuedBytes: Int
        let senderDropHoldActive: Bool
        let unstartedPFrameCount: Int
        let oldestUnstartedPFrameAgeMs: Double
        let oldestUnstartedPFrameLatenessMs: Double
        let queuedUnreliablePendingPackets: Int
        let queuedUnreliableOutstandingPackets: Int
        let queuedUnreliableQueuedBytes: Int
        let queuedUnreliableQueueDwellP99Ms: Double
        let queuedUnreliableSendGapP99Ms: Double
        let queuedUnreliableContentProcessedP99Ms: Double
        let packetPacerFrameMaxSleepMs: Double
        let startupProtectionActive: Bool
        let frameChainRepairActive: Bool
        let realtimePressureState: HostAdaptivePFrameController.PressureState
        let realtimePressureReason: String?
        let transportAdmissionActiveDuration: CFAbsoluteTime

        init(
            mediaPathProfile: MirageMediaPathProfile,
            currentFrameRate: Int,
            receiverState: ReceiverEvidenceState,
            receiverCapacityLearningQuarantineReason: String?,
            receiverReassemblyBacklogFrames: Int,
            receiverReassemblyBacklogBytes: Int,
            receiverDecodeBacklogFrames: Int,
            receiverPresentationBacklogFrames: Int,
            receiverLossHoldActive: Bool,
            receiverAckLagMs: Double?,
            senderQueuedBytes: Int,
            queuePressureBytes: Int,
            maxQueuedBytes: Int,
            senderDropHoldActive: Bool,
            unstartedPFrameCount: Int,
            oldestUnstartedPFrameAgeMs: Double,
            oldestUnstartedPFrameLatenessMs: Double,
            queuedUnreliablePendingPackets: Int,
            queuedUnreliableOutstandingPackets: Int,
            queuedUnreliableQueuedBytes: Int,
            queuedUnreliableQueueDwellP99Ms: Double,
            queuedUnreliableSendGapP99Ms: Double,
            queuedUnreliableContentProcessedP99Ms: Double,
            packetPacerFrameMaxSleepMs: Double = 0,
            startupProtectionActive: Bool,
            frameChainRepairActive: Bool,
            realtimePressureState: HostAdaptivePFrameController.PressureState,
            realtimePressureReason: String?,
            transportAdmissionActiveDuration: CFAbsoluteTime
        ) {
            self.mediaPathProfile = mediaPathProfile
            self.currentFrameRate = max(1, currentFrameRate)
            self.receiverState = receiverState
            self.receiverCapacityLearningQuarantineReason = receiverCapacityLearningQuarantineReason
            self.receiverReassemblyBacklogFrames = max(0, receiverReassemblyBacklogFrames)
            self.receiverReassemblyBacklogBytes = max(0, receiverReassemblyBacklogBytes)
            self.receiverDecodeBacklogFrames = max(0, receiverDecodeBacklogFrames)
            self.receiverPresentationBacklogFrames = max(0, receiverPresentationBacklogFrames)
            self.receiverLossHoldActive = receiverLossHoldActive
            self.receiverAckLagMs = receiverAckLagMs.map { max(0, $0) }
            self.senderQueuedBytes = max(0, senderQueuedBytes)
            self.queuePressureBytes = max(1, queuePressureBytes)
            self.maxQueuedBytes = max(self.queuePressureBytes, maxQueuedBytes)
            self.senderDropHoldActive = senderDropHoldActive
            self.unstartedPFrameCount = max(0, unstartedPFrameCount)
            self.oldestUnstartedPFrameAgeMs = max(0, oldestUnstartedPFrameAgeMs)
            self.oldestUnstartedPFrameLatenessMs = max(0, oldestUnstartedPFrameLatenessMs)
            self.queuedUnreliablePendingPackets = max(0, queuedUnreliablePendingPackets)
            self.queuedUnreliableOutstandingPackets = max(0, queuedUnreliableOutstandingPackets)
            self.queuedUnreliableQueuedBytes = max(0, queuedUnreliableQueuedBytes)
            self.queuedUnreliableQueueDwellP99Ms = max(0, queuedUnreliableQueueDwellP99Ms)
            self.queuedUnreliableSendGapP99Ms = max(0, queuedUnreliableSendGapP99Ms)
            self.queuedUnreliableContentProcessedP99Ms = max(0, queuedUnreliableContentProcessedP99Ms)
            self.packetPacerFrameMaxSleepMs = max(0, packetPacerFrameMaxSleepMs)
            self.startupProtectionActive = startupProtectionActive
            self.frameChainRepairActive = frameChainRepairActive
            self.realtimePressureState = realtimePressureState
            self.realtimePressureReason = realtimePressureReason
            self.transportAdmissionActiveDuration = max(0, transportAdmissionActiveDuration)
        }
    }

    func transportPressureIsActionable(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return true
        }
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            if hasHardSenderPressure(snapshot) || hasHardReceiverPressure(snapshot) {
                return true
            }
            guard pressureReasonIsTransport(snapshot.realtimePressureReason),
                  snapshot.realtimePressureState == .severe,
                  snapshot.receiverState == .severe,
                  snapshot.transportAdmissionActiveDuration >= 2.0,
                  !receiverPressureIsSoftQuarantined(snapshot) else {
                return false
            }
            return true
        }
        if hasLiveSenderPressure(snapshot) {
            return true
        }
        if hasLiveReceiverPressure(snapshot) {
            return true
        }
        if receiverPressureIsSoftQuarantined(snapshot) {
            return false
        }
        guard pressureReasonIsTransport(snapshot.realtimePressureReason),
              snapshot.realtimePressureState == .severe else {
            return false
        }
        return snapshot.receiverState == .severe && snapshot.transportAdmissionActiveDuration >= 1.0
    }

    func receiverPressureIsActionable(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return snapshot.receiverState != .unknown
        }
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            return hasHardReceiverPressure(snapshot)
        }
        if hasLiveReceiverPressure(snapshot) {
            return true
        }
        if snapshot.receiverState == .unknown {
            return false
        }
        if let reason = snapshot.receiverCapacityLearningQuarantineReason,
           Self.softReceiverPressureQuarantineReasons.contains(reason) {
            return false
        }
        return snapshot.receiverState == .severe
    }

    func allowsPreEncodeBudgetReduction(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return true
        }
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            return hasHardSenderPressure(snapshot) ||
                hasHardReceiverPressure(snapshot) ||
                Self.pressureReasonIsMotionComplexity(snapshot.realtimePressureReason)
        }
        if snapshot.startupProtectionActive,
           !hasLiveSenderPressure(snapshot),
           !hasLiveReceiverPressure(snapshot) {
            return false
        }
        return transportPressureIsActionable(snapshot)
    }

    func allowsTransportAdmissionThrottle(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return true
        }
        if snapshot.frameChainRepairActive {
            return true
        }
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            return hasHardSenderPressure(snapshot) || hasHardReceiverPressure(snapshot)
        }
        return transportPressureIsActionable(snapshot)
    }

    func allowsTransportAdmissionStructuralStep(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return true
        }
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            guard snapshot.transportAdmissionActiveDuration >= 2.0 else { return false }
            return hasHardSenderPressure(snapshot) || hasHardReceiverPressure(snapshot)
        }
        guard transportPressureIsActionable(snapshot),
              snapshot.transportAdmissionActiveDuration >= 2.0 else {
            return false
        }
        return snapshot.receiverState == .severe ||
            snapshot.senderQueuedBytes >= snapshot.maxQueuedBytes ||
            snapshot.queuedUnreliableQueuedBytes >= snapshot.queuePressureBytes
    }

    func frameBudgetDecisionIsActionable(
        _ decision: HostFrameBudgetDecision,
        snapshot: TransportPressureSnapshot,
        allowsLocalBulkReductionOverride: Bool = false
    ) -> Bool {
        if decision.state == .observing {
            return true
        }
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return true
        }
        guard snapshot.mediaPathProfile.usesLocalBulkTransportPolicy else {
            return true
        }
        if allowsLocalBulkReductionOverride {
            return true
        }
        switch decision.reason {
        case .startup,
             .healthy:
            return true
        case .encoderLag:
            return true
        case .receiverLoss,
             .receiverBacklog,
             .adaptiveRepair:
            return hasHardReceiverPressure(snapshot) || hasHardSenderPressure(snapshot)
        case .senderDeadline,
             .transportBacklog,
             .pFrameLatency,
             .clientRecovery,
             .receiverFreshness:
            return hasHardSenderPressure(snapshot) || hasHardReceiverPressure(snapshot)
        case .encodedFrame,
             .motionOnset:
            return true
        }
    }

    private func hasLiveSenderPressure(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            return hasHardSenderPressure(snapshot)
        }
        let frameIntervalMs = 1_000.0 / Double(max(1, snapshot.currentFrameRate))
        let queuedPFrameStress = snapshot.unstartedPFrameCount >= 2 &&
            (snapshot.oldestUnstartedPFrameAgeMs >= frameIntervalMs * 2.0 ||
                snapshot.oldestUnstartedPFrameLatenessMs > 0)
        let queuedUnreliableBacklogStress = snapshot.queuedUnreliablePendingPackets >= 8 ||
            snapshot.queuedUnreliableQueuedBytes >= max(32 * 1024, snapshot.queuePressureBytes / 2)
        let queuedUnreliableTimingStress = snapshot.queuedUnreliableQueueDwellP99Ms >= 120 ||
            snapshot.queuedUnreliableContentProcessedP99Ms >= 120 ||
            snapshot.queuedUnreliableSendGapP99Ms >= 120
        let queuedUnreliableQueuePressure = snapshot.queuedUnreliableQueuedBytes >= snapshot.queuePressureBytes
        let packetPacerDebtStress = snapshot.packetPacerFrameMaxSleepMs >= frameIntervalMs * 3.0

        return snapshot.senderDropHoldActive ||
            snapshot.senderQueuedBytes >= snapshot.maxQueuedBytes ||
            queuedPFrameStress ||
            queuedUnreliableQueuePressure ||
            (queuedUnreliableTimingStress && queuedUnreliableBacklogStress) ||
            packetPacerDebtStress
    }

    private func hasLiveReceiverPressure(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.mediaPathProfile.usesLocalBulkTransportPolicy {
            return hasHardReceiverPressure(snapshot)
        }
        if snapshot.receiverLossHoldActive { return true }
        if snapshot.receiverReassemblyBacklogFrames > 0 ||
            snapshot.receiverReassemblyBacklogBytes > 0 {
            return true
        }
        if receiverPressureIsSoftQuarantined(snapshot) {
            return false
        }
        if snapshot.receiverDecodeBacklogFrames >= 4 ||
            snapshot.receiverPresentationBacklogFrames >= 4 {
            return true
        }
        return (snapshot.receiverAckLagMs ?? 0) >= 450
    }

    private func hasHardSenderPressure(_ snapshot: TransportPressureSnapshot) -> Bool {
        snapshot.senderDropHoldActive ||
            snapshot.senderQueuedBytes >= snapshot.maxQueuedBytes ||
            snapshot.queuedUnreliableQueuedBytes >= snapshot.queuePressureBytes ||
            snapshot.queuedUnreliablePendingPackets >= 32 ||
            snapshot.packetPacerFrameMaxSleepMs >= max(250, 1_000.0 / Double(max(1, snapshot.currentFrameRate)) * 8.0)
    }

    private func hasHardReceiverPressure(_ snapshot: TransportPressureSnapshot) -> Bool {
        if snapshot.receiverLossHoldActive { return true }
        if snapshot.receiverReassemblyBacklogFrames >= 4 ||
            snapshot.receiverReassemblyBacklogBytes >= 2_000_000 {
            return true
        }
        if snapshot.receiverDecodeBacklogFrames >= 4 ||
            snapshot.receiverPresentationBacklogFrames >= 4 {
            return true
        }
        return (snapshot.receiverAckLagMs ?? 0) >= 1_000
    }

    private func receiverPressureIsSoftQuarantined(_ snapshot: TransportPressureSnapshot) -> Bool {
        guard let reason = snapshot.receiverCapacityLearningQuarantineReason else { return false }
        return Self.softReceiverPressureQuarantineReasons.contains(reason)
    }

    private static let softReceiverPressureQuarantineReasons: Set<String> = [
        "startup",
        "receiver-feedback-stale",
        "receiver-quarantine",
        "receiver-ack-lag",
        "presentation-underflow"
    ]

    private func pressureReasonIsTransport(_ reason: String?) -> Bool {
        switch reason {
        case HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
             HostAdaptivePFrameController.Reason.senderDeadline.rawValue,
             HostAdaptivePFrameController.Reason.receiverFreshness.rawValue,
             HostAdaptivePFrameController.Reason.pFrameLatency.rawValue,
             HostAdaptivePFrameController.Reason.receiverBacklog.rawValue,
             HostAdaptivePFrameController.Reason.receiverLoss.rawValue,
             "receiver-p-frame-timing":
            return true
        default:
            return false
        }
    }

    static func pressureReasonIsMotionComplexity(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == HostAdaptivePFrameController.Reason.encodedFrame.rawValue ||
            reason == HostAdaptivePFrameController.Reason.motionOnset.rawValue ||
            reason.contains("encoded-frame") ||
            reason.contains("motion-onset")
    }
}
#endif
