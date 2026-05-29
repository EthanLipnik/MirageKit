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
    case sendWithQualityDrop
    case dropPFrameStartChainRepair
    case retryEmergencyKeyframeLowerQuality
    case dropKeyframeWaitForCooldown
    case dropKeyframeWaitForNextLatestFrame
}

struct HostReceiverPressureAssessment: Sendable, Equatable {
    let canCutCeiling: Bool
    let canHoldRaise: Bool
    let canTemporarilyLowerQuality: Bool
    let reason: HostFrameBudgetController.Reason
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
        case pFrameLatency = "p-frame-latency"
        case receiverBacklog = "receiver-backlog"
        case receiverLoss = "receiver-loss"
        case receiverCadence = "receiver-cadence"
        case clientRecovery = "client-recovery"
        case senderDeadline = "sender-deadline"
    }

    private static let minimumDecisionIntervalSeconds: CFAbsoluteTime = 0.12
    private static let pressureCeilingRaiseHoldSeconds: CFAbsoluteTime = 0.45
    private static let severeCeilingRaiseHoldSeconds: CFAbsoluteTime = 0.80
    private static let healthyCeilingRaiseScale = 1.08
    private static let pressureCeilingDropScale = 0.68
    private static let severeCeilingDropScale = 0.45
    private static let pressureQualityCeilingScale: Float = 0.88
    private static let severeQualityCeilingScale: Float = 0.54
    private static let recoveryQualityCeilingScale: Float = 0.68
    private static let cleanFrameRaiseThreshold = 4
    private static let cleanFrameCeilingRaiseThreshold = 24
    private static let cleanFrameQualityRaiseStep: Float = 0.055
    private static let cleanFrameUnderBudgetRatio = 0.82
    private static let cleanFrameCeilingRaiseMinimumRatio = 0.68
    private static let cleanFrameCeilingRaiseMaximumRatio = 0.98
    private static let tinyPFrameOvershootRatio = 1.15
    private static let moderatePFrameOvershootRatio = 1.35
    private static let hardPFrameOvershootRatio = 1.75
    private static let softKeyframeOvershootRatio = 2.25
    private static let softKeyframePacketLimit = 160
    private static let emergencyKeyframeMinimumBudgetBytes = 16 * 1024
    private static let emergencyKeyframeMinimumPacketLimit = 16

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var runtimeCeilingBps: Int?
    private(set) var latestState: PressureState = .observing
    private(set) var latestReason: Reason = .startup
    private(set) var latestDecisionTime: CFAbsoluteTime = 0
    private(set) var latestCeilingDropTime: CFAbsoluteTime = 0
    private var ceilingRaiseHoldUntil: CFAbsoluteTime = 0
    private var consecutivePressureSamples = 0
    private var cleanEncodedFrameCount = 0
    private var nearBudgetCleanEncodedFrameCount = 0
    private var consecutiveOverBudgetFrames = 0
    private var consecutiveOverBudgetKeyframes = 0

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

        let pressure = pressureAssessment(feedback: feedback, currentFrameRate: currentFrameRate)
        let sample = pressure.sample
        let assessment = pressure.assessment
        let targetState: PressureState
        let targetReason: Reason
        if feedback.recoveryState != .idle || feedback.reassemblyBacklogKeyframes > 0 {
            targetState = .recovery
            targetReason = .clientRecovery
            holdReceiverRaiseIfNeeded(now: now, state: targetState)
        } else if sample.isSevere {
            targetState = .severe
            targetReason = sample.reason
            noteReceiverPressure(now: now, state: targetState, assessment: assessment)
        } else if sample.isPressured {
            targetState = sample.repeatedPressureEscalatesToSevere && consecutivePressureSamples >= 2
                ? .severe
                : .pressured
            targetReason = sample.reason
            noteReceiverPressure(now: now, state: targetState, assessment: assessment)
        } else {
            consecutivePressureSamples = 0
            targetState = .observing
            targetReason = .healthy
            if assessment.canHoldRaise {
                holdReceiverRaiseIfNeeded(now: now, state: .pressured)
            }
        }

        let previousCeiling = activeCeiling(input: input)
        let nextCeiling = nextRuntimeCeiling(
            previousCeiling: previousCeiling,
            currentBitrate: input.currentBitrate,
            maximumCeiling: input.maximumCeiling,
            minimumBitrateFloorBps: input.floor,
            state: targetState,
            allowsCeilingCut: assessment.canCutCeiling,
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
            qualityRaiseSuppressionDeadline: qualityRaiseSuppressionDeadline(
                state: targetState,
                assessment: assessment,
                now: now
            ),
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

    mutating func evaluateEncodedFrame(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        isRecoveryKeyframe: Bool = false,
        receiverHealthy: Bool,
        senderHealthy: Bool = true,
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
                isKeyframe: isKeyframe,
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
        nearBudgetCleanEncodedFrameCount = 0
        consecutiveOverBudgetFrames += 1
        if isKeyframe {
            consecutiveOverBudgetKeyframes += 1
        }

        if !isKeyframe, ratio <= Self.tinyPFrameOvershootRatio {
            return HostEncodedFrameAdmissionDecision(
                admission: .sendWithQualityDrop,
                budgetDecision: nil,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let hardPFrameOvershoot = ratio > Self.hardPFrameOvershootRatio ||
            packetRatio > Self.hardPFrameOvershootRatio
        let moderatePFrameOvershoot = ratio > Self.moderatePFrameOvershootRatio
        let state: PressureState = hardPFrameOvershoot || consecutiveOverBudgetFrames >= 3
            ? .severe
            : .pressured
        let nextCeiling = activeCeiling
        runtimeCeilingBps = nextCeiling
        latestState = state
        latestReason = .encodedFrame
        latestDecisionTime = now
        holdCeilingRaise(
            until: now + (state == .severe
                ? Self.severeCeilingRaiseHoldSeconds
                : Self.pressureCeilingRaiseHoldSeconds)
        )

        let decision = makeDecision(
            activeCeilingBps: nextCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: state,
            reason: .encodedFrame,
            ratio: ratio,
            qualityRaiseSuppressionDeadline: now + (state == .severe ? 0.90 : 0.45),
            now: now
        )
        let admission: HostEncodedFrameAdmission
        if isKeyframe {
            if isRecoveryKeyframe,
               recoveryKeyframeFitsBoundedEmergencyBudget(
                   byteCount: byteCount,
                   wireBytes: wireBytes,
                   packetCount: packetCount,
                   budget: budget
               ) {
                consecutiveOverBudgetKeyframes = 0
                admission = .sendWithQualityDrop
            } else if isRecoveryKeyframe {
                admission = consecutiveOverBudgetKeyframes == 1
                    ? .retryEmergencyKeyframeLowerQuality
                    : .dropKeyframeWaitForNextLatestFrame
            } else if ratio <= Self.softKeyframeOvershootRatio,
                      packetCount <= Self.softKeyframePacketLimit {
                consecutiveOverBudgetKeyframes = 0
                admission = .sendWithQualityDrop
            } else {
                admission = consecutiveOverBudgetKeyframes == 1
                    ? .retryEmergencyKeyframeLowerQuality
                    : .dropKeyframeWaitForNextLatestFrame
            }
        } else if !moderatePFrameOvershoot {
            admission = .sendWithQualityDrop
        } else if !hardPFrameOvershoot, senderHealthy {
            admission = .sendWithQualityDrop
        } else {
            admission = .dropPFrameStartChainRepair
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

    private func recoveryKeyframeFitsBoundedEmergencyBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        budget: (maxFrameBytes: Int, maxWireBytes: Int, maxPacketCount: Int, sendDeadline: CFAbsoluteTime)
    ) -> Bool {
        let maxFrameBytes = max(budget.maxFrameBytes, Self.emergencyKeyframeMinimumBudgetBytes)
        let maxWireBytes = max(budget.maxWireBytes, Self.emergencyKeyframeMinimumBudgetBytes)
        let maxPacketCount = max(budget.maxPacketCount, Self.emergencyKeyframeMinimumPacketLimit)
        return byteCount <= maxFrameBytes &&
            wireBytes <= maxWireBytes &&
            packetCount <= maxPacketCount
    }

    mutating func recordSenderDeadlineDrop(
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
    ) -> HostFrameBudgetDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeCeilingIfNeeded(input)
        let previousCeiling = activeCeiling(input: input)
        let nextCeiling = max(
            input.floor,
            min(input.maximumCeiling, Int(Double(min(previousCeiling, input.currentBitrate)) * Self.pressureCeilingDropScale))
        )
        runtimeCeilingBps = nextCeiling
        latestCeilingDropTime = now
        latestState = .severe
        latestReason = .senderDeadline
        latestDecisionTime = now
        cleanEncodedFrameCount = 0
        holdCeilingRaise(until: now + Self.severeCeilingRaiseHoldSeconds)
        return makeDecision(
            activeCeilingBps: nextCeiling,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: .severe,
            reason: .senderDeadline,
            ratio: 1.75,
            qualityRaiseSuppressionDeadline: now + 1.0,
            now: now
        )
    }

    mutating func resetEncodedOvershootHistory() {
        cleanEncodedFrameCount = 0
        nearBudgetCleanEncodedFrameCount = 0
        consecutiveOverBudgetFrames = 0
        consecutiveOverBudgetKeyframes = 0
        consecutivePressureSamples = 0
    }

    private mutating func cleanFrameDecision(
        activeCeiling: Int,
        input: BudgetInput,
        ratio: Double,
        receiverHealthy: Bool,
        isKeyframe: Bool,
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
        guard receiverHealthy, !isKeyframe else {
            cleanEncodedFrameCount = 0
            nearBudgetCleanEncodedFrameCount = 0
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

        if ratio >= Self.cleanFrameCeilingRaiseMinimumRatio,
           ratio <= Self.cleanFrameCeilingRaiseMaximumRatio {
            nearBudgetCleanEncodedFrameCount += 1
        } else {
            nearBudgetCleanEncodedFrameCount = 0
        }

        guard now >= ceilingRaiseHoldUntil else {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let previousCeiling = activeCeiling
        let ceiling = runtimeQualityCeiling(steadyQualityCeiling: steadyQualityCeiling, state: .observing)
        let raisedQuality = min(ceiling, currentQuality + Self.cleanFrameQualityRaiseStep)
        if cleanEncodedFrameCount >= Self.cleanFrameRaiseThreshold,
           raisedQuality > currentQuality + 0.0001 {
            cleanEncodedFrameCount = 0
            runtimeCeilingBps = previousCeiling
            latestState = .observing
            latestReason = .healthy
            latestDecisionTime = now

            let decision = makeDecision(
                activeCeilingBps: previousCeiling,
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

        guard nearBudgetCleanEncodedFrameCount >= Self.cleanFrameCeilingRaiseThreshold,
              previousCeiling < input.maximumCeiling else {
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
        nearBudgetCleanEncodedFrameCount = 0
        let raisedCeiling = min(
            input.maximumCeiling,
            max(previousCeiling + 1, Int(Double(previousCeiling) * Self.healthyCeilingRaiseScale))
        )
        let nextCeiling = max(input.floor, raisedCeiling)
        runtimeCeilingBps = nextCeiling
        latestState = .observing
        latestReason = .healthy
        latestDecisionTime = now

        let decision = makeDecision(
            activeCeilingBps: runtimeCeilingBps ?? nextCeiling,
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

    private func pressureAssessment(
        feedback: ReceiverMediaFeedbackMessage,
        currentFrameRate: Int
    ) -> (
        sample: (isPressured: Bool, isSevere: Bool, repeatedPressureEscalatesToSevere: Bool, reason: Reason),
        assessment: HostReceiverPressureAssessment
    ) {
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
        let presentationCadencePressure = receiverCadenceIsBelowBudget(
            feedback: feedback,
            targetFPS: targetFPS,
            multiplier: 0.82
        )
        let receiveGapMs = max(feedback.receivedWorstGapMs ?? 0, feedback.jitterP95Ms, feedback.jitterP99Ms)
        let hasReceivedCadenceSample = feedback.receivedFPS > 0 || receiveGapMs > frameBudgetMs * 3.0
        let lowReceivedCadence = hasReceivedCadenceSample &&
            feedback.receivedFPS < targetFPS * 0.85
        let sourceCadencePressure = lowReceivedCadence &&
            (receiveGapMs > frameBudgetMs * 3.0 ||
                feedback.jitterP95Ms > frameBudgetMs * 2.0 ||
                feedback.jitterP99Ms > frameBudgetMs * 2.5)
        let sourceCadenceSevere = lowReceivedCadence &&
            feedback.receivedFPS < targetFPS * 0.50 &&
            receiveGapMs > frameBudgetMs * 5.0 &&
            (backlogPressure || transportPressure)
        let pFrameTransportPressure = pFramePressure && (backlogPressure || transportPressure)
        let pFrameTransportSevere = pFrameSevere && (backlogPressure || transportPressure)
        let severe = pFrameTransportSevere || backlogSevere || transportSevere || sourceCadenceSevere
        let pressured = severe ||
            pFrameTransportPressure ||
            backlogPressure ||
            transportPressure ||
            presentationCadencePressure ||
            sourceCadencePressure

        let reason: Reason
        if pFrameTransportSevere || pFrameTransportPressure {
            reason = .pFrameLatency
        } else if backlogPressure {
            reason = .receiverBacklog
        } else if transportPressure {
            reason = .receiverLoss
        } else if presentationCadencePressure || sourceCadencePressure {
            reason = .receiverCadence
        } else {
            reason = .healthy
        }
        let canCutCeiling = backlogPressure || transportPressure
        let canHoldRaise = pressured ||
            feedback.recoveryState != .idle ||
            feedback.reassemblyBacklogKeyframes > 0
        let canTemporarilyLowerQuality = canCutCeiling || presentationCadencePressure || sourceCadencePressure
        return (
            sample: (pressured, severe, canCutCeiling, reason),
            assessment: HostReceiverPressureAssessment(
                canCutCeiling: canCutCeiling,
                canHoldRaise: canHoldRaise,
                canTemporarilyLowerQuality: canTemporarilyLowerQuality,
                reason: reason
            )
        )
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
        allowsCeilingCut: Bool,
        now: CFAbsoluteTime
    ) -> Int {
        let floor = max(1, minimumBitrateFloorBps)
        switch state {
        case .severe:
            guard allowsCeilingCut else { return min(previousCeiling, maximumCeiling) }
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * Self.severeCeilingDropScale))
        case .pressured,
             .recovery:
            guard allowsCeilingCut else { return min(previousCeiling, maximumCeiling) }
            latestCeilingDropTime = now
            return max(floor, Int(Double(min(previousCeiling, currentBitrate)) * Self.pressureCeilingDropScale))
        case .observing:
            return min(previousCeiling, maximumCeiling)
        }
    }

    private func qualityRaiseSuppressionDeadline(
        state: PressureState,
        assessment: HostReceiverPressureAssessment,
        now: CFAbsoluteTime
    ) -> CFAbsoluteTime {
        guard state != .observing else { return 0 }
        if assessment.canTemporarilyLowerQuality {
            return now + (state == .severe ? 0.80 : 0.35)
        }
        if assessment.canHoldRaise || state == .recovery {
            return now + 0.20
        }
        return 0
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
            0.85
        case .severe:
            0.48
        case .recovery:
            0.62
        }
        let ratioScale = Float(max(0.42, min(0.94, 1.0 / max(1.0, ratio))))
        return max(qualityFloor, min(qualityCeiling, currentQuality * min(stateScale, ratioScale)))
    }

    private mutating func notePressure(now: CFAbsoluteTime, state: PressureState) {
        consecutivePressureSamples += 1
        cleanEncodedFrameCount = 0
        nearBudgetCleanEncodedFrameCount = 0
        holdCeilingRaise(
            until: now + (state == .severe
                ? Self.severeCeilingRaiseHoldSeconds
                : Self.pressureCeilingRaiseHoldSeconds)
        )
    }

    private mutating func noteReceiverPressure(
        now: CFAbsoluteTime,
        state: PressureState,
        assessment: HostReceiverPressureAssessment
    ) {
        if assessment.canTemporarilyLowerQuality || assessment.canCutCeiling {
            notePressure(now: now, state: state)
        } else if assessment.canHoldRaise {
            holdReceiverRaiseIfNeeded(now: now, state: state)
        }
    }

    private mutating func holdReceiverRaiseIfNeeded(now: CFAbsoluteTime, state: PressureState) {
        let holdSeconds = state == .severe
            ? Self.severeCeilingRaiseHoldSeconds
            : Self.pressureCeilingRaiseHoldSeconds
        holdCeilingRaise(until: now + holdSeconds)
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
