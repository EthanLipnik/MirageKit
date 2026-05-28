//
//  HostRealtimeStreamBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostRealtimeStreamBudgetController: Equatable {
    enum PressureState: String, Sendable, Equatable {
        case observing
        case pressured
        case severe
        case recovery
    }

    struct Decision: Equatable {
        let targetBitrateBps: Int?
        let runtimeQualityCeiling: Float?
        let frameAdmissionTargetFPS: Int?
        let frameAdmissionDeadline: CFAbsoluteTime
        let qualityRaiseSuppressionDeadline: CFAbsoluteTime
        let state: PressureState
        let reason: String
    }

    private static let healthyRaiseHoldSeconds: CFAbsoluteTime = 0.6
    private static let minimumDecisionIntervalSeconds: CFAbsoluteTime = 0.25
    private static let pressureCeilingDropHoldSeconds: CFAbsoluteTime = 1.0
    private static let severeCeilingDropHoldSeconds: CFAbsoluteTime = 0.75
    private static let pressureQualityCeilingScale: Float = 0.85
    private static let severeQualityCeilingScale: Float = 0.70
    private static let recoveryQualityCeilingScale: Float = 0.75

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var runtimeCeilingBps: Int?
    private(set) var latestState: PressureState = .observing
    private(set) var latestReason: String = "startup"
    private(set) var latestDecisionTime: CFAbsoluteTime = 0
    private(set) var latestCeilingDropTime: CFAbsoluteTime = 0
    private var consecutivePressureSamples = 0
    private var healthySince: CFAbsoluteTime?

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        steadyQualityCeiling: Float,
        now: CFAbsoluteTime
    ) -> Decision? {
        guard feedback.sequence > latestFeedbackSequence else { return nil }
        latestFeedbackSequence = feedback.sequence

        let currentBitrate = max(1, currentBitrateBps ?? requestedTargetBitrateBps ?? startupCeilingBps ?? 1)
        let maximumCeiling = max(
            minimumBitrateFloorBps,
            startupCeilingBps ?? requestedTargetBitrateBps ?? currentBitrate
        )
        if runtimeCeilingBps == nil {
            runtimeCeilingBps = min(currentBitrate, maximumCeiling)
        }

        let sample = pressureSample(
            feedback: feedback,
            currentFrameRate: currentFrameRate
        )
        let targetState: PressureState
        let targetReason: String
        if feedback.recoveryState != .idle || feedback.reassemblyBacklogKeyframes > 0 {
            targetState = .recovery
            targetReason = "client-recovery"
            consecutivePressureSamples = 0
            healthySince = nil
        } else if sample.isSevere {
            targetState = .severe
            targetReason = sample.reason
            consecutivePressureSamples += 1
            healthySince = nil
        } else if sample.isPressured {
            consecutivePressureSamples += 1
            targetState = sample.repeatedPressureEscalatesToSevere && consecutivePressureSamples >= 2
                ? .severe
                : .pressured
            targetReason = sample.reason
            healthySince = nil
        } else {
            consecutivePressureSamples = 0
            targetState = .observing
            targetReason = "healthy"
            if healthySince == nil { healthySince = now }
        }

        let previousCeiling = runtimeCeilingBps ?? min(currentBitrate, maximumCeiling)
        let nextCeiling = nextRuntimeCeiling(
            previousCeiling: previousCeiling,
            currentBitrate: currentBitrate,
            maximumCeiling: maximumCeiling,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            state: targetState,
            now: now
        )
        runtimeCeilingBps = nextCeiling

        let targetBitrate = targetBitrate(
            currentBitrate: currentBitrate,
            nextCeiling: nextCeiling,
            state: targetState
        )
        let qualityCeiling = runtimeQualityCeiling(
            steadyQualityCeiling: steadyQualityCeiling,
            state: targetState
        )
        let suppressionDeadline = targetState == .observing ? 0 : now + 3.0
        let didChange = targetState != latestState ||
            targetReason != latestReason ||
            targetBitrate != nil ||
            abs(Double((qualityCeiling ?? steadyQualityCeiling) - steadyQualityCeiling)) > 0.0001

        guard didChange || now - latestDecisionTime >= Self.minimumDecisionIntervalSeconds else {
            return nil
        }

        latestState = targetState
        latestReason = targetReason
        latestDecisionTime = now

        return Decision(
            targetBitrateBps: targetBitrate,
            runtimeQualityCeiling: qualityCeiling,
            frameAdmissionTargetFPS: nil,
            frameAdmissionDeadline: 0,
            qualityRaiseSuppressionDeadline: suppressionDeadline,
            state: targetState,
            reason: targetReason
        )
    }

    private func pressureSample(
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int
    ) -> (isPressured: Bool, isSevere: Bool, repeatedPressureEscalatesToSevere: Bool, reason: String) {
        let targetFPS = Double(max(1, max(currentFrameRate, feedback.targetFPS)))
        let frameBudgetMs = 1_000.0 / targetFPS
        let pFrameP95 = feedback.pFrameCompletionLatencyP95Ms ?? 0
        let pFramePressure = pFrameP95 > frameBudgetMs * 2.5
        let pFrameSevere = pFrameP95 > frameBudgetMs * 4.0
        let backlogPressure = feedback.reassemblyBacklogFrames > 3 ||
            feedback.reassemblyBacklogBytes > 1_000_000 ||
            feedback.decodeBacklogFrames > 2 ||
            feedback.presentationBacklogFrames > 2
        let backlogSevere = feedback.reassemblyBacklogFrames > 8 ||
            feedback.reassemblyBacklogBytes > 2_000_000 ||
            feedback.decodeBacklogFrames > 4 ||
            feedback.presentationBacklogFrames > 4
        let transportPressure = feedback.lostFrameCount > 0 || feedback.discardedPacketCount > 0
        let transportSevere = feedback.lostFrameCount + feedback.discardedPacketCount >= 6
        let severe = pFrameSevere || backlogSevere || transportSevere
        let pressured = severe ||
            pFramePressure ||
            backlogPressure ||
            transportPressure

        let reason: String
        if pFrameSevere || pFramePressure {
            reason = "p-frame-latency"
        } else if backlogPressure {
            reason = "receiver-backlog"
        } else if transportPressure {
            reason = "receiver-loss"
        } else {
            reason = "healthy"
        }
        return (pressured, severe, true, reason)
    }

    private mutating func nextRuntimeCeiling(
        previousCeiling: Int,
        currentBitrate: Int,
        maximumCeiling: Int,
        minimumBitrateFloorBps: Int,
        state: PressureState,
        now: CFAbsoluteTime
    ) -> Int {
        let floor = max(1, minimumBitrateFloorBps)
        switch state {
        case .severe:
            guard latestCeilingDropTime == 0 ||
                now - latestCeilingDropTime >= Self.severeCeilingDropHoldSeconds else {
                return min(previousCeiling, maximumCeiling)
            }
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * 0.70))
        case .pressured,
             .recovery:
            guard latestCeilingDropTime == 0 ||
                now - latestCeilingDropTime >= Self.pressureCeilingDropHoldSeconds else {
                return min(previousCeiling, maximumCeiling)
            }
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * 0.85))
        case .observing:
            guard let healthySince,
                  now - healthySince >= Self.healthyRaiseHoldSeconds else {
                return min(previousCeiling, maximumCeiling)
            }
            let raised = max(previousCeiling + 1, Int(Double(previousCeiling) * 1.25))
            return min(maximumCeiling, max(floor, raised))
        }
    }

    private func targetBitrate(
        currentBitrate: Int,
        nextCeiling: Int,
        state: PressureState
    ) -> Int? {
        if nextCeiling < currentBitrate {
            return nextCeiling
        }
        guard state == .observing, currentBitrate < nextCeiling else { return nil }
        let raised = min(nextCeiling, max(currentBitrate + 1, Int(Double(currentBitrate) * 1.25)))
        return raised > currentBitrate ? raised : nil
    }

    private func runtimeQualityCeiling(
        steadyQualityCeiling: Float,
        state: PressureState
    ) -> Float? {
        let scale: Float = switch state {
        case .observing:
            1.0
        case .pressured:
            Self.pressureQualityCeilingScale
        case .severe:
            Self.severeQualityCeilingScale
        case .recovery:
            Self.recoveryQualityCeilingScale
        }
        guard scale < 0.999 else { return nil }
        return max(0.05, min(steadyQualityCeiling, steadyQualityCeiling * scale))
    }

}
#endif
