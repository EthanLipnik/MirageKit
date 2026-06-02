//
//  HostStreamTransportController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostStreamTransportController: Equatable {
    enum PressureTrigger: String, Sendable, Equatable {
        case none
        case senderQueue
        case pacerDebt
        case clientTransportLoss
        case clientReassemblyBacklog
        case clientJitter
        case clientPFrameLatency
        case clientDecodePressure
        case clientPresentationBacklog
        case clientPresentationFillDeficit
        case clientPresentationUnderflow
        case clientAwdlDemotion
        case clientRecovery
        case clear
    }

    struct Decision: Equatable {
        var pressureTrigger: PressureTrigger
        var awdlPacingDeadline: CFAbsoluteTime
        var awdlPacingTrigger: PressureTrigger
        var awdlPolicyState: MirageAwdlMediaController.State?
        var awdlPolicyTrigger: MirageAwdlMediaController.Trigger?
        var awdlSelectedLever: MirageAwdlMediaController.SelectedLever?
        var awdlTargetFrameRate: Int?
        var awdlResolutionScale: Double?
        var awdlPlayoutDelayMs: Double?
    }

    private static let awdlPacingHoldSeconds: CFAbsoluteTime = MirageAwdlMediaController.pacingHoldSeconds
    private static let pressureSamplesRequired = 2

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var awdlPacingDeadline: CFAbsoluteTime = 0
    private(set) var latestAwdlMediaDecision: MirageAwdlMediaController.Decision?
    private var consecutivePressureSamples = 0
    private var awdlMediaController = MirageAwdlMediaController()
    private var lastAdvertisedAwdlResolutionScale = 1.0

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        requestedFrameRateCeiling: Int? = nil,
        targetBitrateBps: Int? = nil,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile? = nil,
        senderTelemetry: StreamPacketSender.TelemetrySnapshot? = nil,
        now: CFAbsoluteTime
    ) -> Decision? {
        guard feedback.sequence > latestFeedbackSequence else { return nil }
        latestFeedbackSequence = feedback.sequence
        let mediaProfile = mediaPathProfile ?? MirageMediaPathProfile.classify(
            pathKind: transportPathKind,
            interfaceNames: []
        )
        let awdlDecision = updateAwdlMediaPolicy(
            with: feedback,
            currentFrameRate: currentFrameRate,
            requestedFrameRateCeiling: requestedFrameRateCeiling,
            targetBitrateBps: targetBitrateBps,
            mediaProfile: mediaProfile
        )

        if feedback.recoveryState != .idle ||
            feedback.reassemblyBacklogKeyframes > 0 ||
            awdlDecision?.state == .recovering ||
            awdlDecision?.state == .awaitingFirstFrame ||
            awdlDecision?.state == .failed {
            consecutivePressureSamples = 0
            let awdlDeadline = activateAwdlPacingIfNeeded(
                mediaProfile: mediaProfile,
                now: now,
                holdSeconds: awdlDecision?.pacingHoldSeconds ?? Self.awdlPacingHoldSeconds
            )
            return Decision(
                pressureTrigger: .clear,
                awdlPacingDeadline: awdlDeadline,
                awdlPacingTrigger: awdlDeadline > 0 ? .clientRecovery : .clear,
                awdlPolicyState: awdlDecision?.state,
                awdlPolicyTrigger: awdlDecision?.trigger,
                awdlSelectedLever: awdlDecision?.selectedLever,
                awdlTargetFrameRate: awdlDecision?.targetFrameRate,
                awdlResolutionScale: awdlResolutionScale(for: awdlDecision),
                awdlPlayoutDelayMs: awdlDecision?.playoutDelayMs
            )
        }

        let receiverPressureTrigger: PressureTrigger? = if let awdlDecision {
            Self.pressureTrigger(for: awdlDecision.trigger)
        } else {
            Self.pressureTrigger(
                feedback: feedback,
                currentFrameRate: currentFrameRate,
                mediaPathProfile: mediaProfile
            )
        }
        let pressureTrigger = Self.senderPressureTrigger(
            telemetry: senderTelemetry,
            feedback: feedback,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaProfile
        ) ?? receiverPressureTrigger

        if let pressureTrigger {
            consecutivePressureSamples += 1
            guard consecutivePressureSamples >= Self.pressureSamplesRequired else { return nil }
            if mediaProfile.usesAwdlRadioPolicy {
                let awdlDeadline = activateAwdlPacingIfNeeded(
                    mediaProfile: mediaProfile,
                    now: now,
                    holdSeconds: awdlDecision?.pacingHoldSeconds ?? Self.awdlPacingHoldSeconds
                )
                return Decision(
                    pressureTrigger: pressureTrigger,
                    awdlPacingDeadline: awdlDeadline,
                    awdlPacingTrigger: pressureTrigger,
                    awdlPolicyState: awdlDecision?.state,
                    awdlPolicyTrigger: awdlDecision?.trigger,
                    awdlSelectedLever: awdlDecision?.selectedLever,
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate,
                    awdlResolutionScale: awdlResolutionScale(for: awdlDecision),
                    awdlPlayoutDelayMs: awdlDecision?.playoutDelayMs
                )
            }
            lastAdvertisedAwdlResolutionScale = 1.0
            return Decision(
                pressureTrigger: pressureTrigger,
                awdlPacingDeadline: 0,
                awdlPacingTrigger: .clear,
                awdlPolicyState: nil,
                awdlPolicyTrigger: nil,
                awdlSelectedLever: nil,
                awdlTargetFrameRate: nil,
                awdlResolutionScale: nil,
                awdlPlayoutDelayMs: nil
            )
        }

        consecutivePressureSamples = 0
        if mediaProfile.usesAwdlRadioPolicy {
            if awdlPacingDeadline > 0, now >= awdlPacingDeadline {
                awdlPacingDeadline = 0
                return Decision(
                    pressureTrigger: .clear,
                    awdlPacingDeadline: 0,
                    awdlPacingTrigger: .clear,
                    awdlPolicyState: awdlDecision?.state,
                    awdlPolicyTrigger: awdlDecision?.trigger,
                    awdlSelectedLever: awdlDecision?.selectedLever,
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate,
                    awdlResolutionScale: awdlResolutionScale(for: awdlDecision),
                    awdlPlayoutDelayMs: awdlDecision?.playoutDelayMs
                )
            }
            if let policyOnlyDecision = awdlPolicyOnlyDecisionIfNeeded(
                awdlDecision,
                currentFrameRate: currentFrameRate,
                now: now
            ) {
                return policyOnlyDecision
            }
            return nil
        }
        lastAdvertisedAwdlResolutionScale = 1.0
        return nil
    }

    private mutating func updateAwdlMediaPolicy(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        requestedFrameRateCeiling: Int?,
        targetBitrateBps: Int?,
        mediaProfile: MirageMediaPathProfile
    ) -> MirageAwdlMediaController.Decision? {
        let signal = MirageAwdlMediaController.Signal(
            feedback: feedback,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaProfile,
            requestedFrameRateCeiling: requestedFrameRateCeiling,
            targetBitrateBps: targetBitrateBps
        )
        let decision = awdlMediaController.update(with: signal)
        latestAwdlMediaDecision = mediaProfile.usesAwdlRadioPolicy ? decision : nil
        return latestAwdlMediaDecision
    }

    private static func senderPressureTrigger(
        telemetry: StreamPacketSender.TelemetrySnapshot?,
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> PressureTrigger? {
        guard mediaPathProfile.usesAwdlRadioPolicy,
              let telemetry else {
            return nil
        }
        let targetFrameIntervalMs = 1_000.0 / Double(max(1, max(currentFrameRate, feedback.targetFPS)))
        let queuedPFrameStress = telemetry.unstartedPFrameCount >= 2 &&
            telemetry.oldestUnstartedPFrameAgeMs >= targetFrameIntervalMs * 2.0
        let localDeadlineStress = telemetry.senderLocalDeadlineDrops > 0 ||
            telemetry.stalePacketDrops > 0 ||
            telemetry.lateNonKeyframeSends >= 2
        let queuedUnreliableDropStress = telemetry.queuedUnreliableDeadlineExpiredDrops > 0 ||
            telemetry.queuedUnreliableQueueLimitDrops > 0
        if queuedPFrameStress || localDeadlineStress || queuedUnreliableDropStress {
            return .senderQueue
        }
        let pacerDebtStress = telemetry.packetPacerFrameMaxSleepMs >= Int(targetFrameIntervalMs * 2.0) ||
            telemetry.packetPacerSleepMaxMs >= Int(targetFrameIntervalMs * 2.0)
        return pacerDebtStress ? .pacerDebt : nil
    }

    private mutating func activateAwdlPacingIfNeeded(
        mediaProfile: MirageMediaPathProfile,
        now: CFAbsoluteTime,
        holdSeconds: CFAbsoluteTime
    ) -> CFAbsoluteTime {
        guard mediaProfile.usesAwdlRadioPolicy else {
            awdlPacingDeadline = 0
            return 0
        }
        awdlPacingDeadline = max(awdlPacingDeadline, now + holdSeconds)
        return awdlPacingDeadline
    }

    private mutating func awdlPolicyOnlyDecisionIfNeeded(
        _ awdlDecision: MirageAwdlMediaController.Decision?,
        currentFrameRate: Int,
        now: CFAbsoluteTime
    ) -> Decision? {
        guard let awdlDecision else { return nil }
        let resolutionScale = awdlResolutionScale(for: awdlDecision)
        let targetFrameRate = awdlDecision.targetFrameRate
        let shouldApplyFrameRate = targetFrameRate != currentFrameRate
        let shouldApplyScale = resolutionScale != nil
        guard shouldApplyFrameRate || shouldApplyScale else { return nil }

        let activePacingDeadline = awdlPacingDeadline > now ? awdlPacingDeadline : 0
        return Decision(
            pressureTrigger: .clear,
            awdlPacingDeadline: activePacingDeadline,
            awdlPacingTrigger: .clear,
            awdlPolicyState: awdlDecision.state,
            awdlPolicyTrigger: awdlDecision.trigger,
            awdlSelectedLever: awdlDecision.selectedLever,
            awdlTargetFrameRate: targetFrameRate,
            awdlResolutionScale: resolutionScale,
            awdlPlayoutDelayMs: awdlDecision.playoutDelayMs
        )
    }

    private mutating func awdlResolutionScale(
        for decision: MirageAwdlMediaController.Decision?
    ) -> Double? {
        guard let decision else {
            lastAdvertisedAwdlResolutionScale = 1.0
            return nil
        }

        let scale = min(1.0, max(0.75, decision.resolutionScale))
        if (decision.state == .demoted || decision.state == .failed), scale < 1.0 {
            lastAdvertisedAwdlResolutionScale = scale
            return scale
        }
        if decision.state == .steady,
           lastAdvertisedAwdlResolutionScale < 1.0,
           scale >= 1.0 {
            lastAdvertisedAwdlResolutionScale = 1.0
            return 1.0
        }
        return nil
    }

    private static func pressureTrigger(
        for awdlTrigger: MirageAwdlMediaController.Trigger
    ) -> PressureTrigger? {
        switch awdlTrigger {
        case .jitter:
            .clientJitter
        case .loss:
            .clientTransportLoss
        case .reassemblyBacklog:
            .clientReassemblyBacklog
        case .pFrameLatency:
            .clientPFrameLatency
        case .decodePressure:
            .clientDecodePressure
        case .presentationBacklog:
            .clientPresentationBacklog
        case .presentationFillDeficit:
            .clientPresentationFillDeficit
        case .presentationUnderflow:
            .clientPresentationUnderflow
        case .demote:
            .clientAwdlDemotion
        case .recovery,
             .startup,
             .stable,
             .nonAwdl:
            nil
        }
    }

    private static func pressureTrigger(
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> PressureTrigger? {
        let reassemblyBacklogStress = feedback.reassemblyBacklogFrames >= 8 ||
            feedback.reassemblyBacklogBytes >= 2_000_000
        let droppedStress = feedback.lostFrameCount >= 6 ||
            feedback.discardedPacketCount >= 6 ||
            feedback.lostFrameCount + feedback.discardedPacketCount >= 6
        let targetFrameIntervalMs = 1_000.0 / Double(max(1, max(currentFrameRate, feedback.targetFPS)))
        let receiverJitterP99Ms = feedback.receiverJitterP99Ms ?? 0
        let awdlJitterStress = mediaPathProfile.usesAwdlRadioPolicy &&
            receiverJitterP99Ms >= max(45.0, targetFrameIntervalMs * 3.0)
        let pFrameLatencyP95 = feedback.pFrameCompletionLatencyP95Ms ?? 0
        let receiverPlayoutTargetMs = feedback.playoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs
        let pFrameLatencyThresholdMs = max(
            50.0,
            targetFrameIntervalMs * 3.0,
            min(MirageAwdlMediaController.maximumPlayoutDelayMs, receiverPlayoutTargetMs) +
                targetFrameIntervalMs
        )
        let awdlPFrameLatencyStress = mediaPathProfile.usesAwdlRadioPolicy &&
            (pFrameLatencyP95 >= pFrameLatencyThresholdMs ||
                (feedback.latePFrameCount ?? 0) >= 4)

        if droppedStress {
            return .clientTransportLoss
        }
        if reassemblyBacklogStress {
            return .clientReassemblyBacklog
        }
        if awdlPFrameLatencyStress {
            return .clientPFrameLatency
        }
        if awdlJitterStress {
            return .clientJitter
        }
        return nil
    }

}
#endif
