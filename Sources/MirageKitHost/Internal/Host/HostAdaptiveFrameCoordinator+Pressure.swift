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
    enum CaptureCadenceState: String, Sendable, Equatable {
        case unknown
        case active
        case dynamicIdle = "dynamic-idle"
        case captureStarved = "capture-starved"
        case virtualTimingSuspect = "virtual-timing-suspect"

        var blocksSoftTransportPressure: Bool {
            switch self {
            case .dynamicIdle,
                 .captureStarved,
                 .virtualTimingSuspect:
                true
            case .unknown,
                 .active:
                false
            }
        }
    }

    struct TransportPressureSnapshot: Sendable, Equatable {
        let mediaPathProfile: MirageMediaPathProfile
        let currentFrameRate: Int
        let captureCadenceState: CaptureCadenceState
        let captureCadenceSummary: String?
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
            captureCadenceState: CaptureCadenceState = .unknown,
            captureCadenceSummary: String? = nil,
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
            self.captureCadenceState = captureCadenceState
            self.captureCadenceSummary = captureCadenceSummary
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
        if snapshot.captureCadenceState.blocksSoftTransportPressure,
           !hasHardSenderPressure(snapshot),
           !hasHardReceiverPressure(snapshot) {
            return false
        }
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
        if snapshot.captureCadenceState.blocksSoftTransportPressure,
           !hasHardReceiverPressure(snapshot) {
            return false
        }
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
            return hasHardSenderPressure(snapshot) ||
                hasHardReceiverPressure(snapshot) ||
                Self.pressureReasonIsMotionComplexity(snapshot.realtimePressureReason)
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
        if snapshot.captureCadenceState.blocksSoftTransportPressure,
           !hasHardSenderPressure(snapshot),
           !hasHardReceiverPressure(snapshot),
           decision.reason != .encodedFrame,
           decision.reason != .motionOnset,
           decision.reason != .encoderLag {
            return false
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
        let liveToleranceScale = livePressureToleranceScale(for: snapshot.mediaPathProfile)
        let queuedPFrameAgeThresholdMs = frameIntervalMs * 2.0 * liveToleranceScale
        let queuedPFrameLatenessThresholdMs = liveToleranceScale > 1.0
            ? frameIntervalMs * liveToleranceScale
            : 0
        let queuedPFrameStress = snapshot.unstartedPFrameCount >= 2 &&
            (snapshot.oldestUnstartedPFrameAgeMs >= queuedPFrameAgeThresholdMs ||
                snapshot.oldestUnstartedPFrameLatenessMs > queuedPFrameLatenessThresholdMs)
        let queuedUnreliableBacklogStress = snapshot.queuedUnreliablePendingPackets >= 8 ||
            snapshot.queuedUnreliableQueuedBytes >= max(32 * 1024, snapshot.queuePressureBytes / 2)
        let queuedUnreliableTimingThresholdMs = 120.0 * liveToleranceScale
        let queuedUnreliableTimingStress = snapshot.queuedUnreliableQueueDwellP99Ms >= queuedUnreliableTimingThresholdMs ||
            snapshot.queuedUnreliableContentProcessedP99Ms >= queuedUnreliableTimingThresholdMs ||
            snapshot.queuedUnreliableSendGapP99Ms >= queuedUnreliableTimingThresholdMs
        let queuedUnreliableQueuePressure = snapshot.queuedUnreliableQueuedBytes >= snapshot.queuePressureBytes
        let packetPacerDebtStress = snapshot.packetPacerFrameMaxSleepMs >= frameIntervalMs * 3.0 * liveToleranceScale

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
        return (snapshot.receiverAckLagMs ?? 0) >= 450.0 * livePressureToleranceScale(for: snapshot.mediaPathProfile)
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

    private func livePressureToleranceScale(for mediaPathProfile: MirageMediaPathProfile) -> Double {
        mediaPathProfile.remoteTimingToleranceScale
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

    static func classifyCaptureCadence(
        _ cadence: StreamCaptureCadenceMetrics?,
        targetFrameRate: Int
    ) -> (state: CaptureCadenceState, summary: String?) {
        guard let cadence else {
            return (.unknown, nil)
        }
        let targetFPS = Double(max(1, targetFrameRate))
        let rawFPS = cadence.rawScreenCallbackFPS ?? cadence.completeFrameFPS ?? cadence.observedSCKFPS
        let observedFPS = cadence.observedSCKFPS ?? cadence.renderableFrameFPS ?? cadence.completeFrameFPS
        let renderableFPS = cadence.renderableFrameFPS ?? observedFPS
        let idleFrames = cadence.idleFrameCount ?? 0
        let wallGapP99 = cadence.wallClockGapP99Ms
        let timingSuspect = cadence.virtualDisplayTimingSuspect == true

        let activeRawThreshold = max(6.0, min(15.0, targetFPS * 0.25))
        let idleObservedThreshold = max(2.5, targetFPS * 0.12)
        let rawIsActive = (rawFPS ?? 0) >= activeRawThreshold
        let observedIsLow = (observedFPS ?? renderableFPS ?? 0) <= idleObservedThreshold
        if rawIsActive, observedIsLow, idleFrames >= 3 {
            return (
                .dynamicIdle,
                captureCadenceSummary(
                    state: .dynamicIdle,
                    rawFPS: rawFPS,
                    observedFPS: observedFPS,
                    idleFrames: idleFrames,
                    wallGapP99: wallGapP99
                )
            )
        }

        let starvationRawThreshold = max(1.0, targetFPS * 0.15)
        let rawIsStarved = (rawFPS ?? 0) <= starvationRawThreshold
        let hasLongWallGap = wallGapP99 >= 500 || cadence.longFrameGapCount > 0
        if rawIsStarved, hasLongWallGap {
            return (
                .captureStarved,
                captureCadenceSummary(
                    state: .captureStarved,
                    rawFPS: rawFPS,
                    observedFPS: observedFPS,
                    idleFrames: idleFrames,
                    wallGapP99: wallGapP99
                )
            )
        }

        if timingSuspect,
           wallGapP99 >= 500 || cadence.displayTimeDriftCount > 0 {
            return (
                .virtualTimingSuspect,
                captureCadenceSummary(
                    state: .virtualTimingSuspect,
                    rawFPS: rawFPS,
                    observedFPS: observedFPS,
                    idleFrames: idleFrames,
                    wallGapP99: wallGapP99
                )
            )
        }

        return (
            .active,
            captureCadenceSummary(
                state: .active,
                rawFPS: rawFPS,
                observedFPS: observedFPS,
                idleFrames: idleFrames,
                wallGapP99: wallGapP99
            )
        )
    }

    private static func captureCadenceSummary(
        state: CaptureCadenceState,
        rawFPS: Double?,
        observedFPS: Double?,
        idleFrames: UInt64,
        wallGapP99: Double
    ) -> String {
        let rawText = rawFPS.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "nil"
        let observedText = observedFPS.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "nil"
        let gapText = wallGapP99.formatted(.number.precision(.fractionLength(1)))
        return "\(state.rawValue):raw=\(rawText),observed=\(observedText),idle=\(idleFrames),gapP99=\(gapText)ms"
    }
}
#endif
