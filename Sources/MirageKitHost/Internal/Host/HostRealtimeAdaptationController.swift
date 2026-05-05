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
    private(set) var lastActionTime: CFAbsoluteTime = 0
    private(set) var lastLostFrameCount: UInt64 = 0
    private(set) var lastDiscardedPacketCount: UInt64 = 0

    private let actionCooldown: CFAbsoluteTime = 1.0

    mutating func decide(
        input: HostRealtimeAdaptationInput,
        now: CFAbsoluteTime
    ) -> HostRealtimeAdaptationAction {
        let pressure = pressureAssessment(input: input)
        if pressure.isBudgetFailure {
            sustainedBudgetFailureCount += 1
            stableCount = 0
        } else if pressure.isStable {
            stableCount += 1
            if stableCount >= 8 {
                sustainedBudgetFailureCount = 0
            }
        }
        lastLostFrameCount = input.feedback.lostFrameCount
        lastDiscardedPacketCount = input.feedback.discardedPacketCount

        guard sustainedBudgetFailureCount >= 3 else { return .hold }
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
        let lossAdvanced = feedback.lostFrameCount > lastLostFrameCount ||
            feedback.discardedPacketCount > lastDiscardedPacketCount
        let backlogStressed = feedback.queueEstimateFrames >= max(3, Int(targetFPS / 30.0))
        let jitterStressed = feedback.jitterP95Ms > frameBudgetMs * 2.5
        let receiverBehind = acceptedRatio < 0.88 || decodedRatio < 0.88
        let recovering = feedback.recoveryState != .idle

        var reasons: [String] = []
        if receiverBehind { reasons.append("receiver-fps") }
        if backlogStressed { reasons.append("backlog") }
        if jitterStressed { reasons.append("jitter") }
        if lossAdvanced { reasons.append("loss") }
        if recovering { reasons.append("recovery") }

        let isBudgetFailure = receiverBehind || backlogStressed || jitterStressed || lossAdvanced || recovering
        let isStable = acceptedRatio >= 0.95 &&
            decodedRatio >= 0.95 &&
            feedback.queueEstimateFrames <= 1 &&
            feedback.recoveryState == .idle
        return (
            isBudgetFailure: isBudgetFailure,
            isStable: isStable,
            reason: reasons.isEmpty ? "receiver-budget" : reasons.joined(separator: "+")
        )
    }
}
#endif
