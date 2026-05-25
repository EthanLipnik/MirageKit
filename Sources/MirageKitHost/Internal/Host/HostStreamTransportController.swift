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
    enum FrameAdmissionTrigger: String, Sendable, Equatable {
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
        var frameAdmissionTargetFPS: Int?
        var frameAdmissionDeadline: CFAbsoluteTime
        var qualityRaiseSuppressionDeadline: CFAbsoluteTime
        var frameAdmissionTrigger: FrameAdmissionTrigger
        var awdlPacingDeadline: CFAbsoluteTime
        var awdlPacingTrigger: FrameAdmissionTrigger
        var awdlPolicyState: MirageAwdlMediaController.State?
        var awdlPolicyTrigger: MirageAwdlMediaController.Trigger?
        var awdlTargetFrameRate: Int?
    }

    private static let frameAdmissionHoldSeconds: CFAbsoluteTime = MirageAwdlMediaController.frameAdmissionHoldSeconds
    private static let awdlPacingHoldSeconds: CFAbsoluteTime = MirageAwdlMediaController.pacingHoldSeconds
    private static let qualityRaiseRecoverySuppressionSeconds: CFAbsoluteTime =
        MirageAwdlMediaController.qualityRaiseSuppressionSeconds
    private static let pressureSamplesRequired = 2

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var frameAdmissionTargetFPS: Int?
    private(set) var frameAdmissionDeadline: CFAbsoluteTime = 0
    private(set) var awdlPacingDeadline: CFAbsoluteTime = 0
    private(set) var qualityRaiseSuppressionDeadline: CFAbsoluteTime = 0
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
            let suppressionHold = awdlDecision?.qualityRaiseSuppressionSeconds ??
                Self.qualityRaiseRecoverySuppressionSeconds
            let suppressionDeadline = now + suppressionHold
            qualityRaiseSuppressionDeadline = max(qualityRaiseSuppressionDeadline, suppressionDeadline)
            consecutivePressureSamples = 0
            if frameAdmissionTargetFPS != nil {
                frameAdmissionTargetFPS = nil
                frameAdmissionDeadline = 0
            }
            let awdlDeadline = activateAwdlPacingIfNeeded(
                mediaProfile: mediaProfile,
                now: now,
                holdSeconds: awdlDecision?.pacingHoldSeconds ?? Self.awdlPacingHoldSeconds
            )
            return Decision(
                frameAdmissionTargetFPS: frameAdmissionTargetFPS,
                frameAdmissionDeadline: frameAdmissionDeadline,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: .clear,
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
                let reliefFPS = pressureTrigger == .clientJitter ? nil :
                    awdlDecision?.frameAdmissionTargetFPS ??
                    Self.reliefFrameRate(
                        currentFrameRate: currentFrameRate,
                        activeTargetFPS: frameAdmissionTargetFPS,
                        pressureSampleCount: consecutivePressureSamples
                    )
                frameAdmissionTargetFPS = reliefFPS
                frameAdmissionDeadline = reliefFPS == nil ? 0 :
                    now + (awdlDecision?.frameAdmissionHoldSeconds ?? Self.frameAdmissionHoldSeconds)
                let awdlDeadline = activateAwdlPacingIfNeeded(
                    mediaProfile: mediaProfile,
                    now: now,
                    holdSeconds: awdlDecision?.pacingHoldSeconds ?? Self.awdlPacingHoldSeconds
                )
                return Decision(
                    frameAdmissionTargetFPS: reliefFPS,
                    frameAdmissionDeadline: frameAdmissionDeadline,
                    qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                    frameAdmissionTrigger: pressureTrigger,
                    awdlPacingDeadline: awdlDeadline,
                    awdlPacingTrigger: pressureTrigger,
                    awdlPolicyState: awdlDecision?.state,
                    awdlPolicyTrigger: awdlDecision?.trigger,
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate
                )
            }
            let reliefFPS = Self.reliefFrameRate(
                currentFrameRate: currentFrameRate,
                activeTargetFPS: frameAdmissionTargetFPS,
                pressureSampleCount: consecutivePressureSamples
            )
            frameAdmissionTargetFPS = reliefFPS
            frameAdmissionDeadline = now + Self.frameAdmissionHoldSeconds
            return Decision(
                frameAdmissionTargetFPS: reliefFPS,
                frameAdmissionDeadline: frameAdmissionDeadline,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: pressureTrigger,
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
                frameAdmissionTargetFPS = nil
                frameAdmissionDeadline = 0
                return Decision(
                    frameAdmissionTargetFPS: nil,
                    frameAdmissionDeadline: 0,
                    qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                    frameAdmissionTrigger: .clear,
                    awdlPacingDeadline: 0,
                    awdlPacingTrigger: .clear,
                    awdlPolicyState: awdlDecision?.state,
                    awdlPolicyTrigger: awdlDecision?.trigger,
                    awdlTargetFrameRate: awdlDecision?.targetFrameRate
                )
            }
            return nil
        }
        if frameAdmissionDeadline > 0, now >= frameAdmissionDeadline {
            frameAdmissionTargetFPS = nil
            frameAdmissionDeadline = 0
            return Decision(
                frameAdmissionTargetFPS: nil,
                frameAdmissionDeadline: 0,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: .clear,
                awdlPacingDeadline: 0,
                awdlPacingTrigger: .clear,
                awdlPolicyState: nil,
                awdlPolicyTrigger: nil,
                awdlTargetFrameRate: nil
            )
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
    ) -> FrameAdmissionTrigger? {
        switch awdlTrigger {
        case .jitter:
            .clientJitter
        case .loss:
            .clientTransportLoss
        case .reassemblyBacklog,
             .decodePressure,
             .presentationUnderflow,
             .demote:
            .clientReassemblyBacklog
        case .pFrameLatency:
            .clientPFrameLatency
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
    ) -> FrameAdmissionTrigger? {
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

    private static func reliefFrameRate(
        currentFrameRate: Int,
        activeTargetFPS: Int?,
        pressureSampleCount: Int
    ) -> Int {
        let current = max(1, currentFrameRate)
        if current > 90 {
            if let activeTargetFPS,
               activeTargetFPS <= 90,
               pressureSampleCount >= pressureSamplesRequired * 2 {
                return 60
            }
            return 90
        }
        if current > 60 { return 60 }
        if current > 30 { return 30 }
        return max(15, current)
    }
}
#endif
