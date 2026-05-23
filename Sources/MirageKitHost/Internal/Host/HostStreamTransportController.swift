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
    }

    private static let frameAdmissionHoldSeconds: CFAbsoluteTime = 2.0
    private static let awdlPacingHoldSeconds: CFAbsoluteTime = 2.0
    private static let qualityRaiseRecoverySuppressionSeconds: CFAbsoluteTime = 2.0
    private static let pressureSamplesRequired = 2

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var frameAdmissionTargetFPS: Int?
    private(set) var frameAdmissionDeadline: CFAbsoluteTime = 0
    private(set) var awdlPacingDeadline: CFAbsoluteTime = 0
    private(set) var qualityRaiseSuppressionDeadline: CFAbsoluteTime = 0
    private var consecutivePressureSamples = 0

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        transportPathKind: MirageNetworkPathKind = .unknown,
        now: CFAbsoluteTime
    ) -> Decision? {
        guard feedback.sequence > latestFeedbackSequence else { return nil }
        latestFeedbackSequence = feedback.sequence

        if feedback.recoveryState != .idle || feedback.reassemblyBacklogKeyframes > 0 {
            let suppressionDeadline = now + Self.qualityRaiseRecoverySuppressionSeconds
            qualityRaiseSuppressionDeadline = max(qualityRaiseSuppressionDeadline, suppressionDeadline)
            consecutivePressureSamples = 0
            if frameAdmissionTargetFPS != nil {
                frameAdmissionTargetFPS = nil
                frameAdmissionDeadline = 0
            }
            let awdlDeadline = activateAwdlPacingIfNeeded(
                pathKind: transportPathKind,
                now: now
            )
            return Decision(
                frameAdmissionTargetFPS: frameAdmissionTargetFPS,
                frameAdmissionDeadline: frameAdmissionDeadline,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: .clear,
                awdlPacingDeadline: awdlDeadline,
                awdlPacingTrigger: awdlDeadline > 0 ? .clientRecovery : .clear
            )
        }

        let pressureTrigger = Self.pressureTrigger(
            feedback: feedback,
            currentFrameRate: currentFrameRate,
            transportPathKind: transportPathKind
        )

        if let pressureTrigger {
            consecutivePressureSamples += 1
            guard consecutivePressureSamples >= Self.pressureSamplesRequired else { return nil }
            if transportPathKind == .awdl {
                frameAdmissionTargetFPS = nil
                frameAdmissionDeadline = 0
                let awdlDeadline = activateAwdlPacingIfNeeded(
                    pathKind: transportPathKind,
                    now: now
                )
                return Decision(
                    frameAdmissionTargetFPS: nil,
                    frameAdmissionDeadline: 0,
                    qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                    frameAdmissionTrigger: pressureTrigger,
                    awdlPacingDeadline: awdlDeadline,
                    awdlPacingTrigger: pressureTrigger
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
                awdlPacingTrigger: .clear
            )
        }

        consecutivePressureSamples = 0
        if transportPathKind == .awdl {
            if awdlPacingDeadline > 0, now >= awdlPacingDeadline {
                awdlPacingDeadline = 0
                return Decision(
                    frameAdmissionTargetFPS: nil,
                    frameAdmissionDeadline: 0,
                    qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                    frameAdmissionTrigger: .clear,
                    awdlPacingDeadline: 0,
                    awdlPacingTrigger: .clear
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
                awdlPacingTrigger: .clear
            )
        }

        return nil
    }

    private mutating func activateAwdlPacingIfNeeded(
        pathKind: MirageNetworkPathKind,
        now: CFAbsoluteTime
    ) -> CFAbsoluteTime {
        guard pathKind == .awdl else {
            awdlPacingDeadline = 0
            return 0
        }
        awdlPacingDeadline = max(awdlPacingDeadline, now + Self.awdlPacingHoldSeconds)
        return awdlPacingDeadline
    }

    private static func pressureTrigger(
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
        transportPathKind: MirageNetworkPathKind
    ) -> FrameAdmissionTrigger? {
        let reassemblyBacklogStress = feedback.reassemblyBacklogFrames >= 8 ||
            feedback.reassemblyBacklogBytes >= 2_000_000
        let droppedStress = feedback.lostFrameCount >= 6 ||
            feedback.discardedPacketCount >= 6 ||
            feedback.lostFrameCount + feedback.discardedPacketCount >= 6
        let targetFrameIntervalMs = 1_000.0 / Double(max(1, max(currentFrameRate, feedback.targetFPS)))
        let awdlJitterStress = transportPathKind == .awdl &&
            feedback.jitterP99Ms >= max(60.0, targetFrameIntervalMs * 4.0)
        let pFrameLatencyP95 = feedback.pFrameCompletionLatencyP95Ms ?? 0
        let awdlPFrameLatencyStress = transportPathKind == .awdl &&
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
