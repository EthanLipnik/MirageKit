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
        case clientRecovery
        case clear
    }

    struct Decision: Equatable {
        var pressureTrigger: PressureTrigger
        var awdlPacingDeadline: CFAbsoluteTime
        var awdlPacingTrigger: PressureTrigger
        var awdlPolicyState: MirageAwdlMediaController.State?
        var awdlPolicyTrigger: MirageAwdlMediaController.Trigger?
        var awdlTargetFrameRate: Int?
    }

    private static let awdlPacingHoldSeconds: CFAbsoluteTime = MirageAwdlMediaController.pacingHoldSeconds
    private static let pressureSamplesRequired = 2

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var awdlPacingDeadline: CFAbsoluteTime = 0
    private(set) var latestAwdlMediaDecision: MirageAwdlMediaController.Decision?
    private var consecutivePressureSamples = 0
    private var awdlMediaController = MirageAwdlMediaController()

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile? = nil,
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
            mediaProfile: mediaProfile
        )

        if feedback.recoveryState != .idle ||
            feedback.reassemblyBacklogKeyframes > 0 ||
            awdlDecision?.state == .recovery {
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
                awdlTargetFrameRate: awdlDecision?.targetFrameRate
            )
        }

        let pressureTrigger = if let awdlDecision {
            Self.pressureTrigger(for: awdlDecision.trigger)
        } else {
            Self.pressureTrigger(
                feedback: feedback,
                currentFrameRate: currentFrameRate,
                mediaPathProfile: mediaProfile
            )
        }

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
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate
                )
            }
            return Decision(
                pressureTrigger: pressureTrigger,
                awdlPacingDeadline: 0,
                awdlPacingTrigger: .clear,
                awdlPolicyState: nil,
                awdlPolicyTrigger: nil,
                awdlTargetFrameRate: nil
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
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate
                )
            }
            return nil
        }
        return nil
    }

    private mutating func updateAwdlMediaPolicy(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        mediaProfile: MirageMediaPathProfile
    ) -> MirageAwdlMediaController.Decision? {
        let signal = MirageAwdlMediaController.Signal(
            feedback: feedback,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaProfile
        )
        let decision = awdlMediaController.update(with: signal)
        latestAwdlMediaDecision = mediaProfile.usesAwdlRadioPolicy ? decision : nil
        return latestAwdlMediaDecision
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
        case .decodePressure,
             .presentationUnderflow,
             .demote:
            nil
        case .recovery,
             .warmup,
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
        let awdlJitterStress = mediaPathProfile.usesAwdlRadioPolicy &&
            feedback.jitterP99Ms >= max(60.0, targetFrameIntervalMs * 4.0)
        let pFrameLatencyP95 = feedback.pFrameCompletionLatencyP95Ms ?? 0
        let awdlPFrameLatencyStress = mediaPathProfile.usesAwdlRadioPolicy &&
            (pFrameLatencyP95 >= max(50.0, targetFrameIntervalMs * 3.0) ||
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
