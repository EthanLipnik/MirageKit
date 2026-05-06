//
//  HostRealtimeAdaptationController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Host-owned realtime media adaptation policy.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
struct HostRealtimeAdaptationInput: Sendable, Equatable {
    let feedback: ReceiverMediaFeedbackMessage
    let currentBitrate: Int?
    let activeQuality: Float
    let qualityFloor: Float
    let colorDepth: MirageStreamColorDepth
    let streamScale: CGFloat
    let currentFrameRate: Int
    let appOwnedBitrateAdaptation: Bool
}

enum HostRealtimeAdaptationAction: Sendable, Equatable {
    case hold
    case reduceBitrate(Int, reason: String)
    case reduceQuality(Float, reason: String)
    case reduceColorDepth(MirageStreamColorDepth, reason: String)
    case reduceResolutionScale(CGFloat, reason: String)
    case reduceFrameRate(Int, reason: String)
}

struct HostRealtimeAdaptationController: Sendable, Equatable {
    private(set) var sustainedBudgetFailureCount: Int = 0
    private(set) var stableCount: Int = 0
    private(set) var feedbackSampleCount: Int = 0
    private(set) var firstFeedbackTime: CFAbsoluteTime = 0
    private(set) var lastActionTime: CFAbsoluteTime = 0
    private(set) var lastLostFrameCount: UInt64 = 0
    private(set) var lastDiscardedPacketCount: UInt64 = 0

    private let actionCooldown: CFAbsoluteTime = 1.0
    private let minimumSamplesBeforeAction: Int = 6
    private let minimumObservationDuration: CFAbsoluteTime = 2.0

    mutating func decide(
        input: HostRealtimeAdaptationInput,
        now: CFAbsoluteTime
    ) -> HostRealtimeAdaptationAction {
        guard !input.appOwnedBitrateAdaptation else {
            sustainedBudgetFailureCount = 0
            stableCount = 0
            feedbackSampleCount = 0
            firstFeedbackTime = now
            lastLostFrameCount = input.feedback.lostFrameCount
            lastDiscardedPacketCount = input.feedback.discardedPacketCount
            return .hold
        }

        if firstFeedbackTime == 0 {
            firstFeedbackTime = now
        }
        feedbackSampleCount += 1

        let pressure = pressureAssessment(input: input)
        if input.feedback.recoveryState != .idle {
            sustainedBudgetFailureCount = 0
            stableCount = 0
            feedbackSampleCount = 0
            firstFeedbackTime = now
        } else if pressure.isBudgetFailure {
            sustainedBudgetFailureCount += 1
            stableCount = 0
        } else if pressure.isStable {
            stableCount += 1
            if stableCount >= 4 {
                sustainedBudgetFailureCount = 0
            }
        }
        lastLostFrameCount = input.feedback.lostFrameCount
        lastDiscardedPacketCount = input.feedback.discardedPacketCount

        guard pressure.isBudgetFailure else { return .hold }
        guard sustainedBudgetFailureCount >= 3 else { return .hold }
        guard feedbackSampleCount >= minimumSamplesBeforeAction else { return .hold }
        guard now - firstFeedbackTime >= minimumObservationDuration else { return .hold }
        guard lastActionTime == 0 || now - lastActionTime >= actionCooldown else { return .hold }

        if let bitrateAction = bitrateAction(input: input, reason: pressure.reason) {
            lastActionTime = now
            return bitrateAction
        }

        if input.activeQuality > input.qualityFloor + 0.01 {
            lastActionTime = now
            let nextQuality = max(input.qualityFloor, input.activeQuality - 0.04)
            return .reduceQuality(nextQuality, reason: pressure.reason)
        }

        if sustainedBudgetFailureCount >= 12, input.colorDepth != .standard {
            lastActionTime = now
            return .reduceColorDepth(.standard, reason: pressure.reason)
        }

        if sustainedBudgetFailureCount >= 18, input.streamScale > 0.70 {
            lastActionTime = now
            return .reduceResolutionScale(max(0.70, input.streamScale * 0.90), reason: pressure.reason)
        }

        if sustainedBudgetFailureCount >= 30, input.currentFrameRate > 60 {
            lastActionTime = now
            return .reduceFrameRate(60, reason: pressure.reason)
        }
        if sustainedBudgetFailureCount >= 42, input.currentFrameRate > 30 {
            lastActionTime = now
            return .reduceFrameRate(30, reason: pressure.reason)
        }

        return .hold
    }

    private func bitrateAction(
        input: HostRealtimeAdaptationInput,
        reason: String
    ) -> HostRealtimeAdaptationAction? {
        guard let currentBitrate = input.currentBitrate, currentBitrate > 0 else { return nil }
        let minimumBitrate = input.currentFrameRate >= 120 ? 25_000_000 : 12_000_000
        guard currentBitrate > minimumBitrate else { return nil }
        let nextBitrate = max(minimumBitrate, Int(Double(currentBitrate) * 0.88))
        guard nextBitrate < currentBitrate else { return nil }
        return .reduceBitrate(nextBitrate, reason: reason)
    }

    private func pressureAssessment(input: HostRealtimeAdaptationInput) -> (
        isBudgetFailure: Bool,
        isStable: Bool,
        reason: String
    ) {
        let feedback = input.feedback
        let targetFPS = Double(max(1, feedback.targetFPS))
        let acceptedRatio = feedback.rendererAcceptedFPS / targetFPS
        let decodedRatio = feedback.decodedFPS / targetFPS
        let frameBudgetMs = 1000.0 / targetFPS
        let lostFramesAdvanced = feedback.lostFrameCount > lastLostFrameCount
        let discardedPacketsAdvanced = feedback.discardedPacketCount > lastDiscardedPacketCount
        let reassemblyBacklogStressed = feedback.reassemblyBacklogFrames >= max(6, Int(targetFPS / 10.0)) ||
            feedback.reassemblyBacklogBytes >= 24 * 1024 * 1024
        let jitterStressed = feedback.jitterP95Ms > frameBudgetMs * 2.5 ||
            feedback.jitterP99Ms > frameBudgetMs * 4.0
        let receiverBehind = acceptedRatio < 0.88 || decodedRatio < 0.88
        let recovering = feedback.recoveryState != .idle
        let discardedPacketsPressure = discardedPacketsAdvanced && !recovering
        let transportPressure = !recovering && (lostFramesAdvanced ||
            discardedPacketsPressure ||
            reassemblyBacklogStressed ||
            jitterStressed)

        var reasons: [String] = []
        if lostFramesAdvanced { reasons.append("loss") }
        if discardedPacketsPressure {
            reasons.append("discard")
        } else if discardedPacketsAdvanced {
            reasons.append("discard-telemetry")
        }
        if reassemblyBacklogStressed { reasons.append("reassembly-backlog") }
        if jitterStressed { reasons.append("jitter") }
        if receiverBehind { reasons.append("receiver-fps-telemetry") }
        if recovering { reasons.append("recovery") }

        let isBudgetFailure = transportPressure
        let isStable = !transportPressure &&
            feedback.reassemblyBacklogFrames <= 1 &&
            feedback.reassemblyBacklogBytes < 4 * 1024 * 1024 &&
            feedback.recoveryState == .idle
        return (
            isBudgetFailure: isBudgetFailure,
            isStable: isStable,
            reason: reasons.isEmpty ? "transport-budget" : reasons.joined(separator: "+")
        )
    }
}
#endif
