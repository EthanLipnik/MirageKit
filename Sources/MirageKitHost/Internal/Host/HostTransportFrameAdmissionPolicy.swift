//
//  HostTransportFrameAdmissionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostTransportFrameAdmissionPolicy: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable {
        case normal
        case softThrottle = "soft-throttle"
        case hardThrottle = "hard-throttle"
    }

    struct State: Sendable, Equatable {
        var mode: Mode = .normal
        var activeUntil: CFAbsoluteTime = 0
        var lastAdmittedFrameTime: CFAbsoluteTime = 0
        var lastLoggedMode: Mode = .normal
        var lastSkipLogTime: CFAbsoluteTime = 0
        var hasSenderDropCounterBaseline = false
        var lastSenderLocalDeadlineDrops: UInt64 = 0
        var lastStalePacketDrops: UInt64 = 0
        var lastLateNonKeyframeSends: UInt64 = 0
        var lastQueuedUnreliableDeadlineExpiredDrops: UInt64 = 0
        var lastQueuedUnreliableQueueLimitDrops: UInt64 = 0
    }

    struct Signal: Sendable, Equatable {
        let runtimeAdjustmentEnabled: Bool
        let currentFrameRate: Int
        let mediaPathProfile: MirageMediaPathProfile
        let pressureState: HostAdaptivePFrameController.PressureState
        let pressureReason: String?
        let transportPressureIsActionable: Bool
        let senderQueuedBytes: Int
        let unstartedPFrameCount: Int
        let oldestUnstartedPFrameAgeMs: Double
        let oldestUnstartedPFrameLatenessMs: Double
        let senderLocalDeadlineDrops: UInt64
        let stalePacketDrops: UInt64
        let lateNonKeyframeSends: UInt64
        let queuedUnreliableDeadlineExpiredDrops: UInt64
        let queuedUnreliableQueueLimitDrops: UInt64
        let queuedUnreliablePendingPackets: Int
        let queuedUnreliableOutstandingPackets: Int
        let queuedUnreliableQueuedBytes: Int
        let queuedUnreliableQueueDwellP99Ms: Double
        let queuedUnreliableSendGapP99Ms: Double
        let queuedUnreliableContentProcessedP99Ms: Double
        let queuedUnreliablePendingPacketMax: Int
        let queuedUnreliableOutstandingPacketMax: Int
        let queuedUnreliableQueuedBytesMax: Int
        let queuePressureBytes: Int
        let maxQueuedBytes: Int
        let receiverReassemblyBacklogFrames: Int
        let receiverReassemblyBacklogBytes: Int
        let receiverLossHoldActive: Bool
        let receiverAckLagMs: Double?
        let receiverFeedbackAgeMs: Double?
        let inputActive: Bool
        let sourceStill: Bool

        init(
            runtimeAdjustmentEnabled: Bool,
            currentFrameRate: Int,
            mediaPathProfile: MirageMediaPathProfile,
            pressureState: HostAdaptivePFrameController.PressureState,
            pressureReason: String?,
            transportPressureIsActionable: Bool = true,
            senderTelemetry: StreamPacketSender.TelemetrySnapshot?,
            queuePressureBytes: Int,
            maxQueuedBytes: Int,
            receiverReassemblyBacklogFrames: Int,
            receiverReassemblyBacklogBytes: Int,
            receiverLossHoldActive: Bool,
            receiverAckLagMs: Double?,
            receiverFeedbackAgeMs: Double?,
            inputActive: Bool,
            sourceStill: Bool
        ) {
            self.runtimeAdjustmentEnabled = runtimeAdjustmentEnabled
            self.currentFrameRate = max(1, currentFrameRate)
            self.mediaPathProfile = mediaPathProfile
            self.pressureState = pressureState
            self.pressureReason = pressureReason
            self.transportPressureIsActionable = transportPressureIsActionable
            senderQueuedBytes = max(0, senderTelemetry?.queuedBytes ?? 0)
            unstartedPFrameCount = max(0, senderTelemetry?.unstartedPFrameCount ?? 0)
            oldestUnstartedPFrameAgeMs = max(0, senderTelemetry?.oldestUnstartedPFrameAgeMs ?? 0)
            oldestUnstartedPFrameLatenessMs = max(0, senderTelemetry?.oldestUnstartedPFrameLatenessMs ?? 0)
            senderLocalDeadlineDrops = senderTelemetry?.senderLocalDeadlineDrops ?? 0
            stalePacketDrops = senderTelemetry?.stalePacketDrops ?? 0
            lateNonKeyframeSends = senderTelemetry?.lateNonKeyframeSends ?? 0
            queuedUnreliableDeadlineExpiredDrops = senderTelemetry?.queuedUnreliableDeadlineExpiredDrops ?? 0
            queuedUnreliableQueueLimitDrops = senderTelemetry?.queuedUnreliableQueueLimitDrops ?? 0
            queuedUnreliablePendingPackets = max(0, senderTelemetry?.queuedUnreliablePendingPackets ?? 0)
            queuedUnreliableOutstandingPackets = max(0, senderTelemetry?.queuedUnreliableOutstandingPackets ?? 0)
            queuedUnreliableQueuedBytes = max(0, senderTelemetry?.queuedUnreliableQueuedBytes ?? 0)
            queuedUnreliableQueueDwellP99Ms = max(0, senderTelemetry?.queuedUnreliableQueueDwellP99Ms ?? 0)
            queuedUnreliableSendGapP99Ms = max(0, senderTelemetry?.queuedUnreliableSendGapP99Ms ?? 0)
            queuedUnreliableContentProcessedP99Ms = max(
                0,
                senderTelemetry?.queuedUnreliableContentProcessedP99Ms ?? 0
            )
            queuedUnreliablePendingPacketMax = max(0, senderTelemetry?.queuedUnreliablePendingPacketMax ?? 0)
            queuedUnreliableOutstandingPacketMax = max(0, senderTelemetry?.queuedUnreliableOutstandingPacketMax ?? 0)
            queuedUnreliableQueuedBytesMax = max(0, senderTelemetry?.queuedUnreliableQueuedBytesMax ?? 0)
            self.queuePressureBytes = max(1, queuePressureBytes)
            self.maxQueuedBytes = max(self.queuePressureBytes, maxQueuedBytes)
            self.receiverReassemblyBacklogFrames = max(0, receiverReassemblyBacklogFrames)
            self.receiverReassemblyBacklogBytes = max(0, receiverReassemblyBacklogBytes)
            self.receiverLossHoldActive = receiverLossHoldActive
            self.receiverAckLagMs = receiverAckLagMs.map { max(0, $0) }
            self.receiverFeedbackAgeMs = receiverFeedbackAgeMs.map { max(0, $0) }
            self.inputActive = inputActive
            self.sourceStill = sourceStill
        }
    }

    struct Decision: Sendable, Equatable {
        let admitsFrame: Bool
        let mode: Mode
        let reason: String?
        let evidence: String?
        let minimumFrameIntervalMs: Double
        let activeHoldMs: Double
    }

    private enum Evidence: Sendable, Equatable {
        case none
        case soft(String)
        case hard(String)

        var reason: String? {
            switch self {
            case .none:
                nil
            case .soft(let reason),
                 .hard(let reason):
                reason
            }
        }

        var label: String? {
            switch self {
            case .none:
                nil
            case .soft(let reason):
                "soft:\(reason)"
            case .hard(let reason):
                "hard:\(reason)"
            }
        }
    }

    private struct SenderDropCounterDeltas: Sendable, Equatable {
        let senderLocalDeadlineDrops: UInt64
        let stalePacketDrops: UInt64
        let lateNonKeyframeSends: UInt64
        let lateNonKeyframeSendWindowReachedThreshold: Bool
        let queuedUnreliableDeadlineExpiredDrops: UInt64
        let queuedUnreliableQueueLimitDrops: UInt64
    }

    static func evaluate(
        state: inout State,
        signal: Signal,
        bypass: Bool,
        now: CFAbsoluteTime
    ) -> Decision {
        let senderDropCounterDeltas = consumeSenderDropCounterDeltas(state: &state, signal: signal)
        let currentEvidence = evidence(signal, senderDropCounterDeltas: senderDropCounterDeltas)
        let mode = updateMode(state: &state, signal: signal, evidence: currentEvidence, now: now)
        let intervalMs = minimumFrameIntervalMs(mode: mode, signal: signal)
        let evidenceReason = currentEvidence.reason
        let reason = mode == .normal ? nil : evidenceReason ?? signal.pressureReason
        let activeHoldMs = max(0, (state.activeUntil - now) * 1_000)

        if bypass {
            state.lastAdmittedFrameTime = now
            return Decision(
                admitsFrame: true,
                mode: mode,
                reason: reason,
                evidence: currentEvidence.label,
                minimumFrameIntervalMs: intervalMs,
                activeHoldMs: activeHoldMs
            )
        }

        guard mode != .normal else {
            state.lastAdmittedFrameTime = now
            return Decision(
                admitsFrame: true,
                mode: mode,
                reason: nil,
                evidence: nil,
                minimumFrameIntervalMs: 0,
                activeHoldMs: 0
            )
        }

        let elapsedMs = max(0, (now - state.lastAdmittedFrameTime) * 1_000)
        if state.lastAdmittedFrameTime <= 0 || elapsedMs >= intervalMs {
            state.lastAdmittedFrameTime = now
            return Decision(
                admitsFrame: true,
                mode: mode,
                reason: reason,
                evidence: currentEvidence.label,
                minimumFrameIntervalMs: intervalMs,
                activeHoldMs: activeHoldMs
            )
        }

        return Decision(
            admitsFrame: false,
            mode: mode,
            reason: reason,
            evidence: currentEvidence.label,
            minimumFrameIntervalMs: intervalMs,
            activeHoldMs: activeHoldMs
        )
    }

    static func minimumFrameIntervalMs(mode: Mode, signal: Signal) -> Double {
        let frameIntervalMs = 1_000.0 / Double(max(1, signal.currentFrameRate))
        switch mode {
        case .normal:
            return 0
        case .softThrottle:
            return frameIntervalMs * 2.0
        case .hardThrottle:
            return frameIntervalMs * (signal.mediaPathProfile.usesAwdlRadioPolicy ? 4.0 : 3.0)
        }
    }

    private static func consumeSenderDropCounterDeltas(
        state: inout State,
        signal: Signal
    ) -> SenderDropCounterDeltas {
        let hasBaseline = state.hasSenderDropCounterBaseline
        let lastLateNonKeyframeSends = state.lastLateNonKeyframeSends
        let lateNonKeyframeSendsDelta = senderDropCounterDelta(
            current: signal.lateNonKeyframeSends,
            previous: lastLateNonKeyframeSends,
            hasBaseline: hasBaseline
        )
        let lateNonKeyframeSendWindowReachedThreshold = hasBaseline &&
            signal.lateNonKeyframeSends >= 2 &&
            lastLateNonKeyframeSends < 2

        let deltas = SenderDropCounterDeltas(
            senderLocalDeadlineDrops: senderDropCounterDelta(
                current: signal.senderLocalDeadlineDrops,
                previous: state.lastSenderLocalDeadlineDrops,
                hasBaseline: hasBaseline
            ),
            stalePacketDrops: senderDropCounterDelta(
                current: signal.stalePacketDrops,
                previous: state.lastStalePacketDrops,
                hasBaseline: hasBaseline
            ),
            lateNonKeyframeSends: lateNonKeyframeSendsDelta,
            lateNonKeyframeSendWindowReachedThreshold: lateNonKeyframeSendWindowReachedThreshold,
            queuedUnreliableDeadlineExpiredDrops: senderDropCounterDelta(
                current: signal.queuedUnreliableDeadlineExpiredDrops,
                previous: state.lastQueuedUnreliableDeadlineExpiredDrops,
                hasBaseline: hasBaseline
            ),
            queuedUnreliableQueueLimitDrops: senderDropCounterDelta(
                current: signal.queuedUnreliableQueueLimitDrops,
                previous: state.lastQueuedUnreliableQueueLimitDrops,
                hasBaseline: hasBaseline
            )
        )

        state.hasSenderDropCounterBaseline = true
        state.lastSenderLocalDeadlineDrops = signal.senderLocalDeadlineDrops
        state.lastStalePacketDrops = signal.stalePacketDrops
        state.lastLateNonKeyframeSends = signal.lateNonKeyframeSends
        state.lastQueuedUnreliableDeadlineExpiredDrops = signal.queuedUnreliableDeadlineExpiredDrops
        state.lastQueuedUnreliableQueueLimitDrops = signal.queuedUnreliableQueueLimitDrops
        return deltas
    }

    private static func senderDropCounterDelta(
        current: UInt64,
        previous: UInt64,
        hasBaseline: Bool
    ) -> UInt64 {
        guard hasBaseline else { return 0 }
        guard current >= previous else { return current }
        return current - previous
    }

    private static func updateMode(
        state: inout State,
        signal: Signal,
        evidence: Evidence,
        now: CFAbsoluteTime
    ) -> Mode {
        guard signal.runtimeAdjustmentEnabled || signal.mediaPathProfile.usesAwdlRadioPolicy else {
            state.mode = .normal
            state.activeUntil = 0
            return .normal
        }

        if shouldReleaseImmediately(signal) {
            state.mode = .normal
            state.activeUntil = 0
            return .normal
        }

        switch evidence {
        case .hard:
            state.mode = .hardThrottle
            state.activeUntil = max(state.activeUntil, now + hardHoldSeconds(signal))
        case .soft:
            if state.mode != .hardThrottle || state.activeUntil <= now {
                state.mode = .softThrottle
            }
            state.activeUntil = max(state.activeUntil, now + softHoldSeconds(signal))
        case .none:
            if state.activeUntil <= now {
                state.mode = .normal
                state.activeUntil = 0
            }
        }

        return state.mode
    }

    private static func shouldReleaseImmediately(_ signal: Signal) -> Bool {
        guard signal.sourceStill, !signal.inputActive else { return false }
        guard signal.senderQueuedBytes <= signal.queuePressureBytes / 2,
              signal.queuedUnreliableQueuedBytes <= signal.queuePressureBytes / 2,
              signal.receiverReassemblyBacklogFrames == 0,
              signal.receiverReassemblyBacklogBytes == 0,
              !signal.receiverLossHoldActive else {
            return false
        }
        return true
    }

    private static func evidence(
        _ signal: Signal,
        senderDropCounterDeltas: SenderDropCounterDeltas
    ) -> Evidence {
        let frameIntervalMs = 1_000.0 / Double(max(1, signal.currentFrameRate))
        let liveToleranceScale = livePressureToleranceScale(for: signal.mediaPathProfile)
        let transportReason = pressureReasonIsTransport(signal.pressureReason)
        let usesLocalBulkTransport = signal.mediaPathProfile.usesLocalBulkTransportPolicy
        let hardSenderDropPressure = senderDropCounterDeltas.senderLocalDeadlineDrops > 0 ||
            senderDropCounterDeltas.stalePacketDrops > 0 ||
            senderDropCounterDeltas.queuedUnreliableDeadlineExpiredDrops > 0

        if signal.transportPressureIsActionable,
           signal.pressureState == .severe,
           transportReason {
            return .hard(signal.pressureReason ?? HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
        }
        if signal.senderQueuedBytes >= signal.maxQueuedBytes ||
            senderDropCounterDeltas.queuedUnreliableQueueLimitDrops > 0 ||
            (signal.transportPressureIsActionable &&
                (signal.receiverReassemblyBacklogFrames >= 8 ||
                    signal.receiverReassemblyBacklogBytes >= 2_000_000)) {
            return .hard(HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
        }

        let queuedPFrameStress = signal.unstartedPFrameCount >= 2 &&
            (signal.oldestUnstartedPFrameAgeMs >= frameIntervalMs * 2.0 * liveToleranceScale ||
                signal.oldestUnstartedPFrameLatenessMs > queuedPFrameLatenessThresholdMs(
                    frameIntervalMs: frameIntervalMs,
                    liveToleranceScale: liveToleranceScale
                ))
        let lateNonKeyframeSendStress = senderDropCounterDeltas.lateNonKeyframeSends >= 2 ||
            senderDropCounterDeltas.lateNonKeyframeSendWindowReachedThreshold
        let deadlineStress = hardSenderDropPressure ||
            (!usesLocalBulkTransport && lateNonKeyframeSendStress)
        let liveQueuedUnreliableBacklogStress = signal.queuedUnreliablePendingPackets >= 8 ||
            signal.queuedUnreliableQueuedBytes >= max(32 * 1024, signal.queuePressureBytes / 2)
        let liveQueuedUnreliableQueuePressure = signal.queuedUnreliableQueuedBytes >= signal.queuePressureBytes
        let queuedUnreliableTimingStress = liveQueuedUnreliableBacklogStress &&
            (signal.queuedUnreliableQueueDwellP99Ms >= max(120, frameIntervalMs * 4.0) * liveToleranceScale ||
                signal.queuedUnreliableContentProcessedP99Ms >= max(120, frameIntervalMs * 4.0) * liveToleranceScale ||
                signal.queuedUnreliableSendGapP99Ms >= max(120, frameIntervalMs * 4.0) * liveToleranceScale)
        let receiverTransportStress = signal.transportPressureIsActionable &&
            (signal.receiverLossHoldActive ||
                signal.receiverReassemblyBacklogFrames > 0 ||
                signal.receiverReassemblyBacklogBytes > 0)
        let ackLagStress = signal.transportPressureIsActionable &&
            receiverFeedbackIsFresh(signal) &&
            (signal.receiverAckLagMs ?? 0) >= max(120, frameIntervalMs * 4.0) * liveToleranceScale

        if signal.transportPressureIsActionable,
           signal.pressureState == .pressured,
           transportReason {
            return .soft(signal.pressureReason ?? HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
        }
        if (!usesLocalBulkTransport && queuedPFrameStress) ||
            deadlineStress ||
            liveQueuedUnreliableQueuePressure ||
            (!usesLocalBulkTransport && queuedUnreliableTimingStress) ||
            receiverTransportStress ||
            ackLagStress {
            return .soft(HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
        }
        return .none
    }

    private static func pressureReasonIsTransport(_ reason: String?) -> Bool {
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

    private static func livePressureToleranceScale(for mediaPathProfile: MirageMediaPathProfile) -> Double {
        mediaPathProfile.remoteTimingToleranceScale
    }

    private static func queuedPFrameLatenessThresholdMs(
        frameIntervalMs: Double,
        liveToleranceScale: Double
    ) -> Double {
        liveToleranceScale > 1.0 ? frameIntervalMs * liveToleranceScale : 0
    }

    private static func receiverFeedbackIsFresh(_ signal: Signal) -> Bool {
        guard let receiverFeedbackAgeMs = signal.receiverFeedbackAgeMs else { return false }
        return receiverFeedbackAgeMs <= 1_000
    }

    private static func softHoldSeconds(_ signal: Signal) -> CFAbsoluteTime {
        signal.mediaPathProfile.usesAwdlRadioPolicy ? 0.70 : 0.45
    }

    private static func hardHoldSeconds(_ signal: Signal) -> CFAbsoluteTime {
        signal.mediaPathProfile.usesAwdlRadioPolicy ? 1.10 : 0.80
    }
}
#endif
