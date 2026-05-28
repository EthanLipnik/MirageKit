//
//  HostFrameBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
struct HostFrameBudgetDecision: Sendable, Equatable {
    let targetBitrateBps: Int
    let maxFrameBytes: Int
    let maxWireBytes: Int
    let maxPacketCount: Int
    let quality: Float
    let qualityCeiling: Float
    let keyframeQuality: Float
    let sendDeadline: CFAbsoluteTime
    let qualityRaiseSuppressionDeadline: CFAbsoluteTime
    let state: HostFrameBudgetController.PressureState
    let reason: HostFrameBudgetController.Reason
}

enum HostEncodedFrameAdmission: Sendable, Equatable {
    case send
    case dropPFrameAndRequestKeyframe
    case retryKeyframeAtEmergencyQuality
    case dropKeyframeAndWaitForNext
}

struct HostEncodedFrameAdmissionDecision: Sendable, Equatable {
    let admission: HostEncodedFrameAdmission
    let budgetDecision: HostFrameBudgetDecision?
    let sendDeadline: CFAbsoluteTime
    let byteRatio: Double
    let wireRatio: Double
    let packetRatio: Double

    var isOverBudget: Bool {
        byteRatio > 1.0 || wireRatio > 1.0 || packetRatio > 1.0
    }
}

struct HostFrameBudgetController: Equatable {
    enum PressureState: String, Sendable, Equatable {
        case observing
        case pressured
        case severe
        case recovery
    }

    enum Reason: String, Sendable, Equatable {
        case startup
        case healthy
        case encodedFrame = "encoded-frame"
        case frameChange = "frame-change"
        case pFrameLatency = "p-frame-latency"
        case receiverBacklog = "receiver-backlog"
        case receiverLoss = "receiver-loss"
        case receiverCadence = "receiver-cadence"
        case clientRecovery = "client-recovery"
    }

    private static let minimumDecisionIntervalSeconds: CFAbsoluteTime = 0.12
    private static let healthyRaiseHoldSeconds: CFAbsoluteTime = 0.45
    private static let pressureCeilingRaiseHoldSeconds: CFAbsoluteTime = 0.75
    private static let severeCeilingRaiseHoldSeconds: CFAbsoluteTime = 1.25
    private static let healthyCeilingRaiseScale = 1.12
    private static let pressureCeilingDropScale = 0.62
    private static let severeCeilingDropScale = 0.45
    private static let pressureQualityCeilingScale: Float = 0.78
    private static let severeQualityCeilingScale: Float = 0.52
    private static let recoveryQualityCeilingScale: Float = 0.68
    private static let cleanFrameRaiseThreshold = 8
    private static let cleanFrameQualityRaiseStep: Float = 0.035
    private static let cleanFrameUnderBudgetRatio = 0.72
    private static let advisoryMotionConfidence = 0.78
    private static let advisoryMotionChangedArea = 0.40
    private static let advisoryMotionSevereChangedArea = 0.68
    private static let advisoryMotionAverageDelta = 0.16
    private static let advisoryMotionSevereAverageDelta = 0.28
    private static let recoveryKeyframeBudgetMultiplier = 4.0

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var runtimeCeilingBps: Int?
    private(set) var latestState: PressureState = .observing
    private(set) var latestReason: Reason = .startup
    private(set) var latestDecisionTime: CFAbsoluteTime = 0
    private(set) var latestCeilingDropTime: CFAbsoluteTime = 0
    private var ceilingRaiseHoldUntil: CFAbsoluteTime = 0
    private var consecutivePressureSamples = 0
    private var cleanEncodedFrameCount = 0
    private var consecutiveOverBudgetFrames = 0
    private var consecutiveOverBudgetKeyframes = 0
    private var healthySince: CFAbsoluteTime?

    mutating func update(
        with feedback: ReceiverMediaFeedbackMessage,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard feedback.sequence > latestFeedbackSequence else { return nil }
        latestFeedbackSequence = feedback.sequence

        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeCeilingIfNeeded(input)

        let sample = pressureSample(feedback: feedback, currentFrameRate: currentFrameRate)
        let targetState: PressureState
        let targetReason: Reason
        if feedback.recoveryState != .idle || feedback.reassemblyBacklogKeyframes > 0 {
            targetState = .recovery
            targetReason = .clientRecovery
            notePressure(now: now, state: targetState)
        } else if sample.isSevere {
            targetState = .severe
            targetReason = sample.reason
            notePressure(now: now, state: targetState)
        } else if sample.isPressured {
            targetState = sample.repeatedPressureEscalatesToSevere && consecutivePressureSamples >= 2
                ? .severe
                : .pressured
            targetReason = sample.reason
            notePressure(now: now, state: targetState)
        } else {
            consecutivePressureSamples = 0
            targetState = .observing
            targetReason = .healthy
            if healthySince == nil { healthySince = now }
        }

        let previousCeiling = activeCeiling(input: input)
        let nextCeiling = nextRuntimeCeiling(
            previousCeiling: previousCeiling,
            currentBitrate: input.currentBitrate,
            maximumCeiling: input.maximumCeiling,
            minimumBitrateFloorBps: input.floor,
            state: targetState,
            now: now
        )
        runtimeCeilingBps = nextCeiling

        let decision = makeDecision(
            activeCeilingBps: nextCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: targetState,
            reason: targetReason,
            qualityRaiseSuppressionDeadline: targetState == .observing ? 0 : now + 3.0,
            now: now
        )
        let didChange = targetState != latestState ||
            targetReason != latestReason ||
            nextCeiling != previousCeiling ||
            abs(Double(decision.quality - currentQuality)) > 0.0001

        guard didChange || now - latestDecisionTime >= Self.minimumDecisionIntervalSeconds else {
            return nil
        }

        latestState = targetState
        latestReason = targetReason
        latestDecisionTime = now
        return decision
    }

    mutating func updateForFrameChange(
        estimate: HostFrameChangeEstimate,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard estimate.confidence >= Self.advisoryMotionConfidence else { return nil }
        let isSevere = estimate.changedAreaRatio >= Self.advisoryMotionSevereChangedArea ||
            estimate.averageDelta >= Self.advisoryMotionSevereAverageDelta
        let isPressured = isSevere ||
            estimate.changedAreaRatio >= Self.advisoryMotionChangedArea ||
            estimate.averageDelta >= Self.advisoryMotionAverageDelta
        guard isPressured else { return nil }

        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeCeilingIfNeeded(input)
        let activeCeiling = activeCeiling(input: input)
        let state: PressureState = isSevere ? .severe : .pressured
        notePressure(now: now, state: state)
        let dropScale = state == .severe ? Self.severeCeilingDropScale : Self.pressureCeilingDropScale
        let motionCeiling = max(input.floor, Int(Double(activeCeiling) * dropScale))
        runtimeCeilingBps = min(motionCeiling, input.maximumCeiling)
        latestCeilingDropTime = now
        let decision = makeDecision(
            activeCeilingBps: runtimeCeilingBps ?? motionCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: state,
            reason: .frameChange,
            ratio: isSevere ? 2.2 : 1.55,
            qualityRaiseSuppressionDeadline: now + (isSevere ? 1.25 : 0.75),
            now: now
        )
        guard decision.quality < currentQuality ||
            decision.targetBitrateBps < activeCeiling ||
            state != latestState ||
            latestReason != .frameChange else {
            return nil
        }

        latestState = state
        latestReason = .frameChange
        latestDecisionTime = now
        return decision
    }

    mutating func evaluateEncodedFrame(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        receiverHealthy: Bool,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        now: CFAbsoluteTime
    ) -> HostEncodedFrameAdmissionDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeCeilingIfNeeded(input)
        let activeCeiling = activeCeiling(input: input)
        let budget = frameBudget(
            activeCeilingBps: activeCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            now: now
        )
        let byteRatio = Double(max(0, byteCount)) / Double(max(1, budget.maxFrameBytes))
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, budget.maxWireBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, budget.maxPacketCount))
        let ratio = max(byteRatio, wireRatio, packetRatio)

        guard ratio > 1.0 else {
            consecutiveOverBudgetFrames = 0
            if isKeyframe { consecutiveOverBudgetKeyframes = 0 }
            return cleanFrameDecision(
                activeCeiling: activeCeiling,
                input: input,
                ratio: ratio,
                receiverHealthy: receiverHealthy,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                steadyQualityCeiling: steadyQualityCeiling,
                now: now,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        cleanEncodedFrameCount = 0
        consecutiveOverBudgetFrames += 1
        if isKeyframe {
            consecutiveOverBudgetKeyframes += 1
        }

        let state: PressureState = ratio >= 1.45 || consecutiveOverBudgetFrames >= 2 ? .severe : .pressured
        let scaleLimit = state == .severe ? Self.severeCeilingDropScale : Self.pressureCeilingDropScale
        let proportionalScale = max(0.25, min(scaleLimit, 0.92 / max(1.0, ratio)))
        let nextCeiling = max(input.floor, Int(Double(activeCeiling) * proportionalScale))
        runtimeCeilingBps = min(nextCeiling, input.maximumCeiling)
        latestState = state
        latestReason = .encodedFrame
        latestDecisionTime = now
        latestCeilingDropTime = now
        healthySince = nil
        holdCeilingRaise(
            until: now + (state == .severe
                ? Self.severeCeilingRaiseHoldSeconds
                : Self.pressureCeilingRaiseHoldSeconds)
        )

        let decision = makeDecision(
            activeCeilingBps: runtimeCeilingBps ?? nextCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: state,
            reason: .encodedFrame,
            ratio: ratio,
            qualityRaiseSuppressionDeadline: now + 3.0,
            now: now
        )
        if isKeyframe {
            let recoveryBudget = recoveryKeyframeBudget(
                from: budget,
                currentFrameRate: currentFrameRate,
                now: now
            )
            if byteCount <= recoveryBudget.maxFrameBytes,
               wireBytes <= recoveryBudget.maxWireBytes,
               packetCount <= recoveryBudget.maxPacketCount {
                consecutiveOverBudgetKeyframes = 0
                return HostEncodedFrameAdmissionDecision(
                    admission: .send,
                    budgetDecision: decision,
                    sendDeadline: recoveryBudget.sendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio
                )
            }
        }

        let admission: HostEncodedFrameAdmission
        if isKeyframe {
            admission = consecutiveOverBudgetKeyframes == 1
                ? .retryKeyframeAtEmergencyQuality
                : .dropKeyframeAndWaitForNext
        } else {
            admission = .dropPFrameAndRequestKeyframe
        }
        return HostEncodedFrameAdmissionDecision(
            admission: admission,
            budgetDecision: decision,
            sendDeadline: budget.sendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio
        )
    }

    private mutating func cleanFrameDecision(
        activeCeiling: Int,
        input: BudgetInput,
        ratio: Double,
        receiverHealthy: Bool,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        now: CFAbsoluteTime,
        byteRatio: Double,
        wireRatio: Double,
        packetRatio: Double
    ) -> HostEncodedFrameAdmissionDecision {
        guard receiverHealthy else {
            cleanEncodedFrameCount = 0
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        if ratio <= Self.cleanFrameUnderBudgetRatio {
            cleanEncodedFrameCount += 1
        } else {
            cleanEncodedFrameCount = 0
        }
        guard cleanEncodedFrameCount >= Self.cleanFrameRaiseThreshold,
              now >= ceilingRaiseHoldUntil else {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        cleanEncodedFrameCount = 0
        let previousCeiling = activeCeiling
        let raisedCeiling = min(
            input.maximumCeiling,
            max(previousCeiling + 1, Int(Double(previousCeiling) * Self.healthyCeilingRaiseScale))
        )
        runtimeCeilingBps = max(input.floor, raisedCeiling)
        latestState = .observing
        latestReason = .healthy
        latestDecisionTime = now
        if healthySince == nil { healthySince = now }

        let ceiling = runtimeQualityCeiling(steadyQualityCeiling: steadyQualityCeiling, state: .observing)
        let raisedQuality = min(ceiling, currentQuality + Self.cleanFrameQualityRaiseStep)
        let decision = makeDecision(
            activeCeilingBps: runtimeCeilingBps ?? raisedCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: raisedQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: .observing,
            reason: .healthy,
            qualityRaiseSuppressionDeadline: 0,
            now: now
        )
        return HostEncodedFrameAdmissionDecision(
            admission: .send,
            budgetDecision: decision,
            sendDeadline: decision.sendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio
        )
    }

    private func pressureSample(
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int
    ) -> (isPressured: Bool, isSevere: Bool, repeatedPressureEscalatesToSevere: Bool, reason: Reason) {
        let targetFPS = Double(max(1, max(currentFrameRate, feedback.targetFPS)))
        let frameBudgetMs = 1_000.0 / targetFPS
        let pFrameP95 = feedback.pFrameCompletionLatencyP95Ms ?? 0
        let pFramePressure = pFrameP95 > frameBudgetMs * 2.0
        let pFrameSevere = pFrameP95 > frameBudgetMs * 3.0
        let backlogPressure = feedback.reassemblyBacklogFrames > 2 ||
            feedback.reassemblyBacklogBytes > 650_000 ||
            feedback.decodeBacklogFrames > 1 ||
            feedback.presentationBacklogFrames > 1
        let backlogSevere = feedback.reassemblyBacklogFrames > 5 ||
            feedback.reassemblyBacklogBytes > 1_200_000 ||
            feedback.decodeBacklogFrames > 3 ||
            feedback.presentationBacklogFrames > 3
        let transportPressure = feedback.lostFrameCount > 0 || feedback.discardedPacketCount > 0
        let transportSevere = feedback.lostFrameCount + feedback.discardedPacketCount >= 4
        let receiverCadencePressure = receiverCadenceIsBelowBudget(
            feedback: feedback,
            targetFPS: targetFPS,
            multiplier: 0.82
        )
        let receiverCadenceSevere = receiverCadenceIsBelowBudget(
            feedback: feedback,
            targetFPS: targetFPS,
            multiplier: 0.62
        )
        let severe = pFrameSevere || backlogSevere || transportSevere || receiverCadenceSevere
        let pressured = severe ||
            pFramePressure ||
            backlogPressure ||
            transportPressure ||
            receiverCadencePressure

        let reason: Reason
        if pFrameSevere || pFramePressure {
            reason = .pFrameLatency
        } else if backlogPressure {
            reason = .receiverBacklog
        } else if transportPressure {
            reason = .receiverLoss
        } else if receiverCadencePressure {
            reason = .receiverCadence
        } else {
            reason = .healthy
        }
        return (pressured, severe, true, reason)
    }

    private func receiverCadenceIsBelowBudget(
        feedback: ReceiverMediaFeedbackMessage,
        targetFPS: Double,
        multiplier: Double
    ) -> Bool {
        guard feedback.receivedFPS >= targetFPS * 0.85 else { return false }
        let threshold = targetFPS * multiplier
        let receiverFPS = [feedback.decodedFPS, feedback.rendererAcceptedFPS, feedback.rendererPresentedFPS]
            .filter { $0 > 0 }
            .min()
        guard let receiverFPS else { return false }
        return receiverFPS < threshold
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
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * Self.severeCeilingDropScale))
        case .pressured,
             .recovery:
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * Self.pressureCeilingDropScale))
        case .observing:
            guard now >= ceilingRaiseHoldUntil else {
                return min(previousCeiling, maximumCeiling)
            }
            guard let healthySince,
                  now - healthySince >= Self.healthyRaiseHoldSeconds else {
                return min(previousCeiling, maximumCeiling)
            }
            let raised = max(previousCeiling + 1, Int(Double(previousCeiling) * Self.healthyCeilingRaiseScale))
            return min(maximumCeiling, max(floor, raised))
        }
    }

    private func makeDecision(
        activeCeilingBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        state: PressureState,
        reason: Reason,
        ratio: Double = 1.0,
        qualityRaiseSuppressionDeadline: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let budget = frameBudget(
            activeCeilingBps: activeCeilingBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            now: now
        )
        let ceiling = runtimeQualityCeiling(steadyQualityCeiling: steadyQualityCeiling, state: state)
        let targetQuality = switch state {
        case .observing:
            min(ceiling, max(qualityFloor, currentQuality))
        case .pressured,
             .severe,
             .recovery:
            reducedQuality(
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                qualityCeiling: ceiling,
                state: state,
                ratio: ratio
            )
        }
        let keyframeQuality = max(0.02, min(targetQuality, ceiling * 0.72))
        return HostFrameBudgetDecision(
            targetBitrateBps: activeCeilingBps,
            maxFrameBytes: budget.maxFrameBytes,
            maxWireBytes: budget.maxWireBytes,
            maxPacketCount: budget.maxPacketCount,
            quality: targetQuality,
            qualityCeiling: ceiling,
            keyframeQuality: keyframeQuality,
            sendDeadline: budget.sendDeadline,
            qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline,
            state: state,
            reason: reason
        )
    }

    private func frameBudget(
        activeCeilingBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        now: CFAbsoluteTime
    ) -> (maxFrameBytes: Int, maxWireBytes: Int, maxPacketCount: Int, sendDeadline: CFAbsoluteTime) {
        let fps = max(1, currentFrameRate)
        let maxFrameBytes = max(1, Int((Double(max(1, activeCeilingBps)) / 8.0 / Double(fps)).rounded(.down)))
        let payload = max(1, maxPayloadSize)
        let maxPacketCount = max(1, (maxFrameBytes + payload - 1) / payload)
        return (
            maxFrameBytes: maxFrameBytes,
            maxWireBytes: maxFrameBytes,
            maxPacketCount: maxPacketCount,
            sendDeadline: now + 1.0 / Double(fps)
        )
    }

    private func recoveryKeyframeBudget(
        from budget: (
            maxFrameBytes: Int,
            maxWireBytes: Int,
            maxPacketCount: Int,
            sendDeadline: CFAbsoluteTime
        ),
        currentFrameRate: Int,
        now: CFAbsoluteTime
    ) -> (maxFrameBytes: Int, maxWireBytes: Int, maxPacketCount: Int, sendDeadline: CFAbsoluteTime) {
        let multiplier = Self.recoveryKeyframeBudgetMultiplier
        let fps = max(1, currentFrameRate)
        return (
            maxFrameBytes: max(1, Int((Double(budget.maxFrameBytes) * multiplier).rounded(.down))),
            maxWireBytes: max(1, Int((Double(budget.maxWireBytes) * multiplier).rounded(.down))),
            maxPacketCount: max(1, Int((Double(budget.maxPacketCount) * multiplier).rounded(.up))),
            sendDeadline: now + multiplier / Double(fps)
        )
    }

    private func runtimeQualityCeiling(
        steadyQualityCeiling: Float,
        state: PressureState
    ) -> Float {
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
        return max(0.05, min(steadyQualityCeiling, steadyQualityCeiling * scale))
    }

    private func reducedQuality(
        currentQuality: Float,
        qualityFloor: Float,
        qualityCeiling: Float,
        state: PressureState,
        ratio: Double
    ) -> Float {
        let stateScale: Float = switch state {
        case .observing:
            1.0
        case .pressured:
            0.70
        case .severe:
            0.48
        case .recovery:
            0.62
        }
        let ratioScale = Float(max(0.32, min(0.90, 0.92 / max(1.0, ratio))))
        return max(qualityFloor, min(qualityCeiling, currentQuality * min(stateScale, ratioScale)))
    }

    private mutating func notePressure(now: CFAbsoluteTime, state: PressureState) {
        consecutivePressureSamples += 1
        cleanEncodedFrameCount = 0
        healthySince = nil
        holdCeilingRaise(
            until: now + (state == .severe
                ? Self.severeCeilingRaiseHoldSeconds
                : Self.pressureCeilingRaiseHoldSeconds)
        )
    }

    private mutating func holdCeilingRaise(until deadline: CFAbsoluteTime) {
        if deadline > ceilingRaiseHoldUntil { ceilingRaiseHoldUntil = deadline }
    }

    private mutating func initializeCeilingIfNeeded(_ input: BudgetInput) {
        if runtimeCeilingBps == nil {
            runtimeCeilingBps = min(input.currentBitrate, input.maximumCeiling)
        }
    }

    private func activeCeiling(input: BudgetInput) -> Int {
        max(input.floor, min(runtimeCeilingBps ?? input.currentBitrate, input.maximumCeiling))
    }

    private func budgetInput(
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int
    ) -> BudgetInput {
        let currentBitrate = max(1, currentBitrateBps ?? requestedTargetBitrateBps ?? startupCeilingBps ?? 1)
        let floor = max(1, minimumBitrateFloorBps)
        let maximumCeiling = max(floor, startupCeilingBps ?? requestedTargetBitrateBps ?? currentBitrate)
        return BudgetInput(
            currentBitrate: currentBitrate,
            maximumCeiling: maximumCeiling,
            floor: floor
        )
    }

    private struct BudgetInput: Equatable {
        let currentBitrate: Int
        let maximumCeiling: Int
        let floor: Int
    }
}
#endif
