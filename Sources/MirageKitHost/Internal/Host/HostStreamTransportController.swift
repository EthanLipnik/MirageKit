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
        case clear
    }

    struct Decision: Equatable {
        var frameAdmissionTargetFPS: Int?
        var frameAdmissionDeadline: CFAbsoluteTime
        var qualityRaiseSuppressionDeadline: CFAbsoluteTime
        var frameAdmissionTrigger: FrameAdmissionTrigger
    }

    private static let frameAdmissionHoldSeconds: CFAbsoluteTime = 2.0
    private static let qualityRaiseRecoverySuppressionSeconds: CFAbsoluteTime = 2.0
    private static let pressureSamplesRequired = 2

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var frameAdmissionTargetFPS: Int?
    private(set) var frameAdmissionDeadline: CFAbsoluteTime = 0
    private(set) var qualityRaiseSuppressionDeadline: CFAbsoluteTime = 0
    private var consecutivePressureSamples = 0

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int,
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
            return Decision(
                frameAdmissionTargetFPS: frameAdmissionTargetFPS,
                frameAdmissionDeadline: frameAdmissionDeadline,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: .clear
            )
        }

        let reassemblyBacklogStress = feedback.reassemblyBacklogFrames >= 8 ||
            feedback.reassemblyBacklogBytes >= 2_000_000
        let droppedStress = feedback.lostFrameCount >= 6 ||
            feedback.discardedPacketCount >= 6 ||
            feedback.lostFrameCount + feedback.discardedPacketCount >= 6
        let pressureTrigger: FrameAdmissionTrigger? = if droppedStress {
            .clientTransportLoss
        } else if reassemblyBacklogStress {
            .clientReassemblyBacklog
        } else {
            nil
        }

        if let pressureTrigger {
            consecutivePressureSamples += 1
            guard consecutivePressureSamples >= Self.pressureSamplesRequired else { return nil }
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
                frameAdmissionTrigger: pressureTrigger
            )
        }

        consecutivePressureSamples = 0
        if frameAdmissionDeadline > 0, now >= frameAdmissionDeadline {
            frameAdmissionTargetFPS = nil
            frameAdmissionDeadline = 0
            return Decision(
                frameAdmissionTargetFPS: nil,
                frameAdmissionDeadline: 0,
                qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
                frameAdmissionTrigger: .clear
            )
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
