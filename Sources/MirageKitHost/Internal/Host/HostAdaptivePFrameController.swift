//
//  HostAdaptivePFrameController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
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
    let state: HostAdaptivePFrameController.PressureState
    let reason: HostAdaptivePFrameController.Reason
}

enum HostEncodedFrameAdmission: Sendable, Equatable {
    case send
    case sendWithQualityDrop
    case dropPFrameStartChainRepair
    case dropKeyframeRetryLowerScale
}

enum TimingSource: Sendable, Equatable {
    case remoteAck
    case clientAssembled
    case clientPacketArrival
    case localSendCompletion
}

struct HostPFrameSendSample: Sendable, Equatable {
    let frameNumber: UInt64
    let wireBytes: Int
    let packetCount: Int
    let serviceTimeMs: Double
    let timingSource: TimingSource
    let receiverHealthy: Bool
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

struct HostAdaptivePFrameController: Equatable {
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
        case clientRecovery = "client-recovery"
        case senderDeadline = "sender-deadline"
        case adaptiveRepair = "adaptive-repair"
    }

    private struct BudgetInput: Equatable {
        let currentBitrate: Int
        let maximumCeiling: Int
        let floor: Int
    }

    private struct PFrameBudget: Equatable {
        let ceilingWireBytes: Int
        let operatingTargetWireBytes: Int
        let burstLimitWireBytes: Int
        let ceilingPacketCount: Int
        let operatingTargetPacketCount: Int
        let burstLimitPacketCount: Int
        let sendDeadline: CFAbsoluteTime
    }

    private struct PFrameSpikeAssessment: Equatable {
        let hasBaseline: Bool
        let ratio: Double
        let allowedRatio: Double
        let allowedPacketCount: Int
        let isMajor: Bool

        static let none = PFrameSpikeAssessment(
            hasBaseline: false,
            ratio: 1.0,
            allowedRatio: HostAdaptivePFrameController.pFrameSpikeMaximumRatio,
            allowedPacketCount: Int.max,
            isMajor: false
        )
    }

    private struct PFrameSizeTrend: Equatable {
        let hasPrevious: Bool
        let grew: Bool
        let qualityProbeGrowth: Bool
        let ratio: Double

        var contentGrowth: Bool {
            grew && !qualityProbeGrowth
        }

        var allowsQualityRaise: Bool {
            !grew || !hasPrevious
        }
    }

    private enum PFrameServiceState: Equatable {
        case excellent
        case acceptable
        case slow
        case bad
        case severe

        var holdDownSeconds: CFAbsoluteTime {
            switch self {
            case .excellent,
                 .acceptable:
                0
            case .slow:
                5
            case .bad:
                15
            case .severe:
                30
            }
        }

        var pressureState: PressureState {
            self == .severe ? .severe : .pressured
        }

        var qualityRatio: Double {
            switch self {
            case .excellent,
                 .acceptable:
                1.0
            case .slow:
                1.20
            case .bad:
                1.55
            case .severe:
                2.20
            }
        }

        var isSlowOrWorse: Bool {
            switch self {
            case .excellent,
                 .acceptable:
                false
            case .slow,
                 .bad,
                 .severe:
                true
            }
        }
    }

    private static let operatingTargetRatio = 0.70
    private static let burstLimitRatio = 0.90
    private static let pFrameServiceTargetMsAt60FPS = 8.0
    private static let pFrameExcellentMsAt60FPS = 8.0
    private static let pFrameAcceptableMsAt60FPS = 14.0
    private static let pFrameSlowMsAt60FPS = 20.0
    private static let pFrameBadMsAt60FPS = 30.0
    private static let learnedThroughputUtilization = 0.80
    private static let probeIntervalSeconds: CFAbsoluteTime = 0.75
    private static let probeRaiseScale = 1.05
    private static let receiverLossCutScale = 0.80
    private static let receiverSevereCutScale = 0.35
    private static let normalTimingCutScale = 0.85
    private static let severeTimingCutScale = 0.65
    private static let capacityCutMinimumIntervalSeconds: CFAbsoluteTime = 1.0
    private static let localWiFiInitialOperatingTargetAt60FPS = 40 * 1024
    private static let minimumCeilingWireBytes = 6 * 1024
    private static let minimumLatencyOnlyCeilingWireBytesAt60FPS = 32 * 1024
    private static let minimumPacketCount = 8
    private static let minimumMeaningfulCleanBaselineSampleBytes = 12 * 1024
    private static let cleanBaselineSeedSampleCount = 3
    private static let cleanBaselineSeedSampleLimit = 8
    private static let recentEligibleServiceStateLimit = 3
    private static let minimumThroughputLearningWireBytesAt60FPS = 16 * 1024
    private static let pFrameSpikeBaselinePivotKB = 16.0
    private static let pFrameSpikeMaximumRatio = 3.5
    private static let pFrameSpikeMinimumRatio = 1.25
    private static let pFrameSpikeLogStepScale = 0.35
    private static let pFrameSpikePacketSlack = 8
    private static let smallAbsoluteOvershootBytes = 64 * 1024
    private static let adaptiveRepairTargetTolerance = 1.10
    private static let maximumImmediateOvershootRatio = 1.15
    private static let qualityProbeGrowthTolerance: Float = 0.004
    private static let qualityProbeGrowthMaximumRatio = 1.20
    private static let contentGrowthMaximumQualityScale: Float = 0.96
    private static let highHeadroomQualityFloorStartBps = 120_000_000
    private static let highHeadroomQualityFloorFullBps = 180_000_000
    private static let highHeadroomQualityFloorAtStart: Float = 0.58
    private static let highHeadroomQualityFloorAtFull: Float = 0.70

    private(set) var latestFeedbackSequence: UInt64 = 0
    private(set) var runtimeCeilingBps: Int?
    private(set) var latestState: PressureState = .observing
    private(set) var latestReason: Reason = .startup
    private(set) var latestDecisionTime: CFAbsoluteTime = 0
    private(set) var transportCeilingWireBytes: Int?
    private(set) var operatingTargetWireBytes: Int?
    private(set) var burstLimitWireBytes: Int?
    private(set) var recentCleanPFrameBaselineWireBytes: Int?
    private(set) var recentCleanPFrameBaselinePacketCount: Int?
    private(set) var adaptiveRepairTargetWireBytes: Int?
    private(set) var adaptiveRepairTargetPacketCount: Int?
    private(set) var holdDownUntil: CFAbsoluteTime = 0
    private(set) var lastAdmittedPFrameWireBytes: Int?
    private(set) var lastAdmittedPFramePacketCount: Int?
    private(set) var lastAdmittedPFrameQuality: Float?
    private var latestCeilingDropTime: CFAbsoluteTime = 0
    private var lastProbeTime: CFAbsoluteTime = 0
    private var pendingCleanBaselineWireBytes: [Int] = []
    private var pendingCleanBaselinePacketCounts: [Int] = []
    private var recentEligibleServiceStates: [PFrameServiceState] = []

    static func allowedPFrameSpikeRatio(baselineWireBytes: Int) -> Double {
        let baselineKB = max(1.0, Double(max(1, baselineWireBytes)) / 1024.0)
        let logSteps = max(0.0, log2(baselineKB / Self.pFrameSpikeBaselinePivotKB))
        return min(
            Self.pFrameSpikeMaximumRatio,
            max(
                Self.pFrameSpikeMinimumRatio,
                Self.pFrameSpikeMaximumRatio - Self.pFrameSpikeLogStepScale * logSteps
            )
        )
    }

    static func allowedPFrameSpikePacketCount(
        baselinePacketCount: Int,
        allowedSpikeRatio: Double
    ) -> Int {
        let baseline = max(1, baselinePacketCount)
        return max(
            baseline + Self.pFrameSpikePacketSlack,
            Int((Double(baseline) * allowedSpikeRatio).rounded(.up))
        )
    }

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
        initializeCeilingIfNeeded(input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize)

        let pressure = receiverPressure(feedback: feedback)
        guard pressure.state != .observing else { return nil }

        let previousCeiling = currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
        if pressure.cutsCeiling {
            let scale = pressure.state == .severe ? Self.receiverSevereCutScale : Self.receiverLossCutScale
            setTransportCeilingWireBytes(
                Int((Double(previousCeiling) * scale).rounded(.down)),
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            latestCeilingDropTime = now
        }
        holdDownUntil = max(holdDownUntil, now + pressure.holdDownSeconds)
        latestState = pressure.state
        latestReason = pressure.reason
        latestDecisionTime = now

        return makeDecision(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: pressure.state,
            reason: pressure.reason,
            quality: reducedQuality(
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                qualityCeiling: runtimeQualityCeiling(steadyQualityCeiling: steadyQualityCeiling, state: pressure.state),
                ratio: pressure.qualityRatio
            ),
            now: now
        )
    }

    mutating func evaluateEncodedFrame(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        isRecoveryKeyframe: Bool = false,
        adaptiveKeyframeAllowed: Bool = true,
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
        initializeCeilingIfNeeded(input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize)
        let budget = pFrameBudget(input: input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize, now: now)
        let byteRatio = Double(max(0, byteCount)) / Double(max(1, budget.ceilingWireBytes))
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, budget.ceilingWireBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, budget.ceilingPacketCount))
        let ceilingRatio = max(wireRatio, packetRatio)

        if isKeyframe {
            if isRecoveryKeyframe,
               let repairTarget = adaptiveRepairTargetWireBytes,
               wireBytes > Int((Double(repairTarget) * Self.adaptiveRepairTargetTolerance).rounded(.up)) {
                let decision = makeDecision(
                    input: input,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize,
                    currentQuality: currentQuality,
                    qualityFloor: qualityFloor,
                    steadyQualityCeiling: steadyQualityCeiling,
                    state: .recovery,
                    reason: .adaptiveRepair,
                    quality: max(0.02, min(currentQuality * 0.45, steadyQualityCeiling * 0.35)),
                    now: now
                )
                return HostEncodedFrameAdmissionDecision(
                    admission: .dropKeyframeRetryLowerScale,
                    budgetDecision: decision,
                    sendDeadline: budget.sendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio
                )
            }
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let spike = pFrameSpikeAssessment(wireBytes: wireBytes, packetCount: packetCount)
        let trend = pFrameSizeTrend(wireBytes: wireBytes, packetCount: packetCount, currentQuality: currentQuality)

        if wireBytes <= budget.ceilingWireBytes,
           packetCount <= budget.ceilingPacketCount {
            let decision: HostFrameBudgetDecision?
            if trend.contentGrowth {
                let nextQuality = nextContentGrowthQuality(
                    currentQuality: currentQuality,
                    qualityFloor: qualityFloor,
                    growthRatio: trend.ratio,
                    minimumQuality: contentGrowthMinimumQuality(
                        qualityFloor: qualityFloor,
                        steadyQualityCeiling: steadyQualityCeiling,
                        budget: budget,
                        currentFrameRate: currentFrameRate,
                        wireBytes: wireBytes,
                        packetCount: packetCount
                    )
                )
                decision = makeDecision(
                    input: input,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize,
                    currentQuality: currentQuality,
                    qualityFloor: qualityFloor,
                    steadyQualityCeiling: steadyQualityCeiling,
                    state: .pressured,
                    reason: .encodedFrame,
                    quality: nextQuality,
                    now: now
                )
                return admittedPFrameDecision(
                    admission: .sendWithQualityDrop,
                    budgetDecision: decision,
                    sendDeadline: budget.sendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio,
                    wireBytes: wireBytes,
                    packetCount: packetCount,
                    currentQuality: currentQuality
                )
            } else if receiverHealthy, trend.allowsQualityRaise {
                let raisedQuality = cleanPFrameQuality(
                    currentQuality: currentQuality,
                    qualityFloor: qualityFloor,
                    steadyQualityCeiling: steadyQualityCeiling,
                    wireBytes: wireBytes,
                    budget: budget
                )
                decision = raisedQuality > currentQuality + 0.0001
                    ? makeDecision(
                        input: input,
                        currentFrameRate: currentFrameRate,
                        maxPayloadSize: maxPayloadSize,
                        currentQuality: currentQuality,
                        qualityFloor: qualityFloor,
                        steadyQualityCeiling: steadyQualityCeiling,
                        state: .observing,
                        reason: .healthy,
                        quality: raisedQuality,
                        now: now
                    )
                    : nil
            } else {
                decision = nil
            }
            return admittedPFrameDecision(
                admission: .send,
                budgetDecision: decision,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                wireBytes: wireBytes,
                packetCount: packetCount,
                currentQuality: currentQuality
            )
        }

        let nextQuality = trend.contentGrowth
            ? nextContentGrowthQuality(
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                growthRatio: trend.ratio,
                minimumQuality: contentGrowthMinimumQuality(
                    qualityFloor: qualityFloor,
                    steadyQualityCeiling: steadyQualityCeiling,
                    budget: budget,
                    currentFrameRate: currentFrameRate,
                    wireBytes: wireBytes,
                    packetCount: packetCount
                )
            )
            : nextOvershootQuality(
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                operatingTargetWireBytes: budget.operatingTargetWireBytes,
                wireBytes: wireBytes
            )
        let pressureState: PressureState = ceilingRatio > 1.50 || spike.isMajor ? .severe : .pressured
        let cutDecision = makeDecision(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: pressureState,
            reason: .encodedFrame,
            quality: nextQuality,
            now: now
        )

        if wireBytes <= budget.ceilingWireBytes,
           packetCount <= budget.ceilingPacketCount {
            return HostEncodedFrameAdmissionDecision(
                admission: .sendWithQualityDrop,
                budgetDecision: cutDecision,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let smallAbsoluteOvershoot = wireBytes <= Self.smallAbsoluteOvershootBytes && packetCount <= 48
        let immediateOvershootSafe = ceilingRatio <= Self.maximumImmediateOvershootRatio && receiverHealthy && senderHealthy
        let majorAdaptiveSpike = spike.isMajor && !smallAbsoluteOvershoot
        if majorAdaptiveSpike, adaptiveKeyframeAllowed, !immediateOvershootSafe {
            setAdaptiveRepairTarget(
                droppedPFrameWireBytes: wireBytes,
                droppedPFramePacketCount: packetCount,
                budget: budget,
                maxPayloadSize: maxPayloadSize
            )
            latestState = .recovery
            latestReason = .adaptiveRepair
            latestDecisionTime = now
            return HostEncodedFrameAdmissionDecision(
                admission: .dropPFrameStartChainRepair,
                budgetDecision: cutDecision,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        if immediateOvershootSafe || smallAbsoluteOvershoot || (!spike.isMajor && receiverHealthy && senderHealthy) {
            return admittedPFrameDecision(
                admission: .sendWithQualityDrop,
                budgetDecision: cutDecision,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                wireBytes: wireBytes,
                packetCount: packetCount,
                currentQuality: currentQuality
            )
        }

        if adaptiveKeyframeAllowed {
            setAdaptiveRepairTarget(
                droppedPFrameWireBytes: wireBytes,
                droppedPFramePacketCount: packetCount,
                budget: budget,
                maxPayloadSize: maxPayloadSize
            )
            return HostEncodedFrameAdmissionDecision(
                admission: .dropPFrameStartChainRepair,
                budgetDecision: cutDecision,
                sendDeadline: budget.sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        return admittedPFrameDecision(
            admission: .sendWithQualityDrop,
            budgetDecision: cutDecision,
            sendDeadline: budget.sendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio,
            wireBytes: wireBytes,
            packetCount: packetCount,
            currentQuality: currentQuality
        )
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
        initializeCeilingIfNeeded(input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize)
        setTransportCeilingWireBytes(
            Int((Double(currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)) * 0.80).rounded(.down)),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        holdDownUntil = max(holdDownUntil, now + 5)
        latestState = .pressured
        latestReason = .senderDeadline
        latestDecisionTime = now
        return makeDecision(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: .pressured,
            reason: .senderDeadline,
            quality: max(qualityFloor, currentQuality * 0.80),
            now: now
        )
    }

    mutating func recordFreshnessPressure(
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
        initializeCeilingIfNeeded(input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize)
        latestState = .pressured
        latestReason = .senderDeadline
        latestDecisionTime = now
        return makeDecision(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: .pressured,
            reason: .senderDeadline,
            quality: max(qualityFloor, currentQuality * 0.45),
            now: now
        )
    }

    mutating func recordFrameTransportCompletion(
        frameNumber: UInt64 = 0,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        sendCompletionMs: Double,
        timingSource: TimingSource = .localSendCompletion,
        receiverHealthy: Bool = true,
        capacityLearningAllowed: Bool = true,
        capacityLearningQuarantineReason: String? = nil,
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
        guard !isKeyframe, sendCompletionMs >= 0 else { return nil }
        guard timingSource == .remoteAck ||
            timingSource == .clientAssembled ||
            timingSource == .clientPacketArrival else {
            return nil
        }

        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeCeilingIfNeeded(input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize)
        let sample = HostPFrameSendSample(
            frameNumber: frameNumber,
            wireBytes: wireBytes,
            packetCount: packetCount,
            serviceTimeMs: sendCompletionMs,
            timingSource: timingSource,
            receiverHealthy: receiverHealthy
        )
        let serviceState = pFrameServiceState(serviceTimeMs: sendCompletionMs, currentFrameRate: currentFrameRate)
        let eligibleThroughputSample = isThroughputLearningSample(sample, currentFrameRate: currentFrameRate)
        if receiverHealthy, capacityLearningAllowed, eligibleThroughputSample {
            recordEligibleServiceState(serviceState)
        }
        switch serviceState {
        case .slow:
            guard receiverHealthy, capacityLearningAllowed, eligibleThroughputSample else {
                logCapacitySampleDecision(
                    sample: sample,
                    serviceState: serviceState,
                    currentFrameRate: currentFrameRate,
                    accepted: false,
                    quarantineReason: receiverHealthy
                        ? (eligibleThroughputSample ? (capacityLearningQuarantineReason ?? "capacity-quarantined") : "sample-too-small")
                        : "receiver-unhealthy",
                    oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                    newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
                )
                return nil
            }
            logCapacitySampleDecision(
                sample: sample,
                serviceState: serviceState,
                currentFrameRate: currentFrameRate,
                accepted: false,
                quarantineReason: "slow-observed",
                oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
            )
            return nil

        case .bad,
             .severe:
            guard receiverHealthy, capacityLearningAllowed else {
                logCapacitySampleDecision(
                    sample: sample,
                    serviceState: serviceState,
                    currentFrameRate: currentFrameRate,
                    accepted: false,
                    quarantineReason: capacityLearningQuarantineReason ?? (receiverHealthy ? "capacity-quarantined" : "receiver-unhealthy"),
                    oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                    newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
                )
                return nil
            }
            guard eligibleThroughputSample else {
                logCapacitySampleDecision(
                    sample: sample,
                    serviceState: serviceState,
                    currentFrameRate: currentFrameRate,
                    accepted: false,
                    quarantineReason: "sample-too-small",
                    oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                    newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
                )
                return nil
            }
            let badOrWorseCount = recentEligibleServiceStates.filter { $0 == .bad || $0 == .severe }.count
            guard badOrWorseCount >= 2 else {
                logCapacitySampleDecision(
                    sample: sample,
                    serviceState: serviceState,
                    currentFrameRate: currentFrameRate,
                    accepted: false,
                    quarantineReason: "waiting-for-2-of-3-bad",
                    oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                    newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
                )
                return nil
            }
            guard now - latestCeilingDropTime >= Self.capacityCutMinimumIntervalSeconds else {
                holdDownUntil = max(holdDownUntil, now + serviceState.holdDownSeconds)
                logCapacitySampleDecision(
                    sample: sample,
                    serviceState: serviceState,
                    currentFrameRate: currentFrameRate,
                    accepted: false,
                    quarantineReason: "post-cut-hold",
                    oldCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate),
                    newCeiling: currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
                )
                return nil
            }
            let learnedBytes = learnedSafePFrameWireBytes(
                sample: sample,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            let previousCeiling = currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
            let severeEvidence = serviceState == .severe &&
                recentEligibleServiceStates.filter { $0 == .severe }.count >= 2
            let cutScale = severeEvidence ? Self.severeTimingCutScale : Self.normalTimingCutScale
            let cutFloor = Int((Double(previousCeiling) * cutScale).rounded(.down))
            let latencyFloor = minimumLatencyOnlyCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
            let newCeiling = min(previousCeiling, max(learnedBytes, cutFloor, latencyFloor))
            setTransportCeilingWireBytes(
                newCeiling,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            decayRecentCleanBaselineAfterTransportCeilingCut(newCeiling: newCeiling)
            latestCeilingDropTime = now
            holdDownUntil = max(holdDownUntil, now + serviceState.holdDownSeconds)
            latestState = serviceState.pressureState
            latestReason = .pFrameLatency
            latestDecisionTime = now
            logCapacitySampleDecision(
                sample: sample,
                serviceState: serviceState,
                currentFrameRate: currentFrameRate,
                accepted: newCeiling < previousCeiling,
                quarantineReason: newCeiling < previousCeiling ? nil : "latency-floor",
                oldCeiling: previousCeiling,
                newCeiling: newCeiling
            )
            return makeDecision(
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                steadyQualityCeiling: steadyQualityCeiling,
                state: serviceState.pressureState,
                reason: .pFrameLatency,
                quality: reducedQuality(
                    currentQuality: currentQuality,
                    qualityFloor: qualityFloor,
                    qualityCeiling: runtimeQualityCeiling(
                        steadyQualityCeiling: steadyQualityCeiling,
                        state: serviceState.pressureState
                    ),
                    ratio: serviceState.qualityRatio
                ),
                now: now
            )

        case .excellent,
             .acceptable:
            if receiverHealthy, capacityLearningAllowed {
                updateRecentCleanPFrameBaseline(
                    sample: sample,
                    input: input,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize,
                    now: now
                )
            }
        }

        guard receiverHealthy,
              capacityLearningAllowed,
              now >= holdDownUntil,
              now - lastProbeTime >= Self.probeIntervalSeconds else {
            return nil
        }

        lastProbeTime = now
        let previousCeiling = currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
        let raisedCeiling = Int((Double(previousCeiling) * Self.probeRaiseScale).rounded(.up))
        setTransportCeilingWireBytes(
            raisedCeiling,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        guard currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate) > previousCeiling else {
            return nil
        }
        latestState = .observing
        latestReason = .healthy
        latestDecisionTime = now
        return makeDecision(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            state: .observing,
            reason: .healthy,
            quality: currentQuality,
            now: now
        )
    }

    mutating func resetEncodedOvershootHistory() {
        adaptiveRepairTargetWireBytes = nil
        adaptiveRepairTargetPacketCount = nil
        lastAdmittedPFrameWireBytes = nil
        lastAdmittedPFramePacketCount = nil
        lastAdmittedPFrameQuality = nil
    }

    private mutating func setAdaptiveRepairTarget(
        droppedPFrameWireBytes: Int,
        droppedPFramePacketCount: Int,
        budget: PFrameBudget,
        maxPayloadSize: Int
    ) {
        let operating = Double(max(1, budget.operatingTargetWireBytes))
        let dropped = Double(max(1, droppedPFrameWireBytes))
        let geometricMidpoint = sqrt(operating * dropped)
        let repairBurstCap = max(Double(budget.burstLimitWireBytes), operating * 1.85)
        let target = min(
            repairBurstCap,
            max(operating * 1.35, geometricMidpoint)
        )
        adaptiveRepairTargetWireBytes = max(1, Int(target.rounded(.up)))
        let packetTarget = max(
            budget.burstLimitPacketCount,
            (max(1, adaptiveRepairTargetWireBytes ?? 1) + max(1, maxPayloadSize) - 1) / max(1, maxPayloadSize)
        )
        adaptiveRepairTargetPacketCount = min(
            packetTarget,
            max(droppedPFramePacketCount - 1, budget.operatingTargetPacketCount)
        )
    }

    private mutating func updateRecentCleanPFrameBaseline(
        sample: HostPFrameSendSample,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        now: CFAbsoluteTime
    ) {
        guard sample.wireBytes >= Self.minimumCeilingWireBytes else { return }
        let clampedWireBytes = clampCeilingWireBytes(
            sample.wireBytes,
            input: input,
            currentFrameRate: currentFrameRate
        )
        let clampedPacketCount = max(Self.minimumPacketCount, sample.packetCount)
        guard let existingWireBytes = recentCleanPFrameBaselineWireBytes,
              let existingPacketCount = recentCleanPFrameBaselinePacketCount else {
            guard clampedWireBytes >= Self.minimumMeaningfulCleanBaselineSampleBytes else { return }
            seedRecentCleanPFrameBaseline(wireBytes: clampedWireBytes, packetCount: clampedPacketCount)
            if let baseline = recentCleanPFrameBaselineWireBytes {
                let baselineCeiling = Int((Double(baseline) / Self.operatingTargetRatio).rounded(.up))
                setTransportCeilingWireBytes(
                    max(currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate), baselineCeiling),
                    input: input,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize
                )
            }
            return
        }

        if clampedWireBytes <= existingWireBytes {
            return
        }

        guard isMeaningfulCleanBaselineSample(wireBytes: clampedWireBytes, input: input, currentFrameRate: currentFrameRate) else {
            return
        }
        guard now >= holdDownUntil,
              now - lastProbeTime >= Self.probeIntervalSeconds else {
            return
        }
        recentCleanPFrameBaselineWireBytes = min(
            clampedWireBytes,
            max(existingWireBytes + 1, Int((Double(existingWireBytes) * 1.12).rounded(.up)))
        )
        recentCleanPFrameBaselinePacketCount = min(
            clampedPacketCount,
            max(existingPacketCount + 1, Int((Double(existingPacketCount) * 1.12).rounded(.up)))
        )
        let nextCeiling = Int((Double(recentCleanPFrameBaselineWireBytes ?? clampedWireBytes) / Self.operatingTargetRatio)
            .rounded(.up))
        setTransportCeilingWireBytes(
            max(currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate), nextCeiling),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private mutating func seedRecentCleanPFrameBaseline(wireBytes: Int, packetCount: Int) {
        guard wireBytes >= Self.minimumCeilingWireBytes else { return }
        pendingCleanBaselineWireBytes.append(wireBytes)
        pendingCleanBaselinePacketCounts.append(packetCount)
        if pendingCleanBaselineWireBytes.count > Self.cleanBaselineSeedSampleLimit {
            pendingCleanBaselineWireBytes.removeFirst(pendingCleanBaselineWireBytes.count - Self.cleanBaselineSeedSampleLimit)
        }
        if pendingCleanBaselinePacketCounts.count > Self.cleanBaselineSeedSampleLimit {
            pendingCleanBaselinePacketCounts.removeFirst(pendingCleanBaselinePacketCounts.count - Self.cleanBaselineSeedSampleLimit)
        }
        guard pendingCleanBaselineWireBytes.count >= Self.cleanBaselineSeedSampleCount,
              pendingCleanBaselinePacketCounts.count >= Self.cleanBaselineSeedSampleCount else {
            return
        }
        recentCleanPFrameBaselineWireBytes = median(pendingCleanBaselineWireBytes)
        recentCleanPFrameBaselinePacketCount = median(pendingCleanBaselinePacketCounts)
        pendingCleanBaselineWireBytes.removeAll(keepingCapacity: true)
        pendingCleanBaselinePacketCounts.removeAll(keepingCapacity: true)
    }

    private mutating func decayRecentCleanBaselineAfterTransportCeilingCut(newCeiling: Int) {
        guard let existingWireBytes = recentCleanPFrameBaselineWireBytes else { return }
        let cappedBaseline = max(
            Self.minimumCeilingWireBytes,
            Int((Double(max(1, newCeiling)) * Self.operatingTargetRatio).rounded(.down))
        )
        guard existingWireBytes > cappedBaseline else { return }
        recentCleanPFrameBaselineWireBytes = cappedBaseline
        if let existingPacketCount = recentCleanPFrameBaselinePacketCount {
            recentCleanPFrameBaselinePacketCount = max(
                Self.minimumPacketCount,
                Int((Double(existingPacketCount) * Double(cappedBaseline) / Double(max(1, existingWireBytes))).rounded(.up))
            )
        }
    }

    private func isMeaningfulCleanBaselineSample(
        wireBytes: Int,
        input: BudgetInput,
        currentFrameRate: Int
    ) -> Bool {
        let operatingTarget = currentOperatingTargetWireBytes(input: input, currentFrameRate: currentFrameRate)
        let threshold = max(
            Self.minimumMeaningfulCleanBaselineSampleBytes,
            Int((Double(max(1, operatingTarget)) * 0.35).rounded(.up))
        )
        return wireBytes >= threshold
    }

    private func pFrameSpikeAssessment(wireBytes: Int, packetCount: Int) -> PFrameSpikeAssessment {
        guard let baselineWireBytes = recentCleanPFrameBaselineWireBytes,
              let baselinePacketCount = recentCleanPFrameBaselinePacketCount else {
            return .none
        }
        let allowedRatio = Self.allowedPFrameSpikeRatio(baselineWireBytes: baselineWireBytes)
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, baselineWireBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, baselinePacketCount))
        let allowedPacketCount = Self.allowedPFrameSpikePacketCount(
            baselinePacketCount: baselinePacketCount,
            allowedSpikeRatio: allowedRatio
        )
        return PFrameSpikeAssessment(
            hasBaseline: true,
            ratio: max(wireRatio, packetRatio),
            allowedRatio: allowedRatio,
            allowedPacketCount: allowedPacketCount,
            isMajor: wireRatio > allowedRatio || packetCount > allowedPacketCount
        )
    }

    private func pFrameSizeTrend(
        wireBytes: Int,
        packetCount: Int,
        currentQuality: Float
    ) -> PFrameSizeTrend {
        guard let previousWireBytes = lastAdmittedPFrameWireBytes,
              let previousPacketCount = lastAdmittedPFramePacketCount else {
            return PFrameSizeTrend(
                hasPrevious: false,
                grew: false,
                qualityProbeGrowth: false,
                ratio: 1.0
            )
        }
        let wireRatio = Double(max(1, wireBytes)) / Double(max(1, previousWireBytes))
        let packetRatio = Double(max(1, packetCount)) / Double(max(1, previousPacketCount))
        let ratio = max(1.0, max(wireRatio, packetRatio))
        let grew = wireBytes > previousWireBytes || packetCount > previousPacketCount
        let qualityProbeGrowth = grew &&
            currentQuality > (lastAdmittedPFrameQuality ?? currentQuality) + Self.qualityProbeGrowthTolerance &&
            ratio <= Self.qualityProbeGrowthMaximumRatio
        return PFrameSizeTrend(
            hasPrevious: true,
            grew: grew,
            qualityProbeGrowth: qualityProbeGrowth,
            ratio: ratio
        )
    }

    private mutating func admittedPFrameDecision(
        admission: HostEncodedFrameAdmission,
        budgetDecision: HostFrameBudgetDecision?,
        sendDeadline: CFAbsoluteTime,
        byteRatio: Double,
        wireRatio: Double,
        packetRatio: Double,
        wireBytes: Int,
        packetCount: Int,
        currentQuality: Float
    ) -> HostEncodedFrameAdmissionDecision {
        lastAdmittedPFrameWireBytes = max(0, wireBytes)
        lastAdmittedPFramePacketCount = max(0, packetCount)
        lastAdmittedPFrameQuality = currentQuality
        return HostEncodedFrameAdmissionDecision(
            admission: admission,
            budgetDecision: budgetDecision,
            sendDeadline: sendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio
        )
    }

    private func receiverPressure(
        feedback: ReceiverMediaFeedbackMessage
    ) -> (state: PressureState, reason: Reason, cutsCeiling: Bool, holdDownSeconds: CFAbsoluteTime, qualityRatio: Double) {
        let hasLoss = feedback.lostFrameCount > 0 || feedback.discardedPacketCount > 0
        let severeLoss = feedback.lostFrameCount + feedback.discardedPacketCount >= 4
        if severeLoss {
            return (.severe, .receiverLoss, true, 30, 1.80)
        }
        if hasLoss {
            return (.pressured, .receiverLoss, true, 15, 1.35)
        }
        return (.observing, .healthy, false, 0, 1.0)
    }

    private func cleanPFrameQuality(
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        wireBytes: Int,
        budget: PFrameBudget
    ) -> Float {
        let ratio = Double(max(1, wireBytes)) / Double(max(1, budget.operatingTargetWireBytes))
        let additiveStep: Float
        let multiplicativeScale: Float
        if ratio <= 0.50 {
            additiveStep = 0.10
            multiplicativeScale = 1.30
        } else if ratio <= 0.70 {
            additiveStep = 0.07
            multiplicativeScale = 1.20
        } else {
            additiveStep = 0.04
            multiplicativeScale = 1.12
        }
        return min(
            steadyQualityCeiling,
            max(qualityFloor, max(currentQuality + additiveStep, currentQuality * multiplicativeScale))
        )
    }

    private func nextOvershootQuality(
        currentQuality: Float,
        qualityFloor: Float,
        operatingTargetWireBytes: Int,
        wireBytes: Int
    ) -> Float {
        let ratio = Double(max(1, operatingTargetWireBytes)) / Double(max(1, wireBytes))
        let scale = Float(min(0.85, max(0.08, ratio)))
        return max(qualityFloor, currentQuality * scale)
    }

    private func nextContentGrowthQuality(
        currentQuality: Float,
        qualityFloor: Float,
        growthRatio: Double,
        minimumQuality: Float
    ) -> Float {
        let scale = Float(min(Double(Self.contentGrowthMaximumQualityScale), max(0.08, 1.0 / max(1.0, growthRatio))))
        return max(qualityFloor, minimumQuality, currentQuality * scale)
    }

    private func contentGrowthMinimumQuality(
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        budget: PFrameBudget,
        currentFrameRate: Int,
        wireBytes: Int,
        packetCount: Int
    ) -> Float {
        guard wireBytes <= budget.operatingTargetWireBytes,
              packetCount <= budget.operatingTargetPacketCount else {
            return qualityFloor
        }
        let ceilingBps = bitrateForWireBytes(budget.ceilingWireBytes, currentFrameRate: currentFrameRate)
        guard ceilingBps >= Self.highHeadroomQualityFloorStartBps else {
            return qualityFloor
        }
        let progressDenominator = max(1, Self.highHeadroomQualityFloorFullBps - Self.highHeadroomQualityFloorStartBps)
        let progress = Float(
            max(
                0.0,
                min(1.0, Double(ceilingBps - Self.highHeadroomQualityFloorStartBps) / Double(progressDenominator))
            )
        )
        let bitrateBackedFloor = Self.highHeadroomQualityFloorAtStart +
            progress * (Self.highHeadroomQualityFloorAtFull - Self.highHeadroomQualityFloorAtStart)
        return max(qualityFloor, min(steadyQualityCeiling, bitrateBackedFloor))
    }

    private func reducedQuality(
        currentQuality: Float,
        qualityFloor: Float,
        qualityCeiling: Float,
        ratio: Double
    ) -> Float {
        let scale = Float(min(0.90, max(0.42, 1.0 / max(1.0, ratio))))
        return max(qualityFloor, min(qualityCeiling, currentQuality * scale))
    }

    private func runtimeQualityCeiling(
        steadyQualityCeiling: Float,
        state: PressureState
    ) -> Float {
        switch state {
        case .observing:
            steadyQualityCeiling
        case .pressured:
            max(0.05, steadyQualityCeiling * 0.95)
        case .severe:
            max(0.05, steadyQualityCeiling * 0.75)
        case .recovery:
            max(0.05, steadyQualityCeiling * 0.70)
        }
    }

    private func pFrameServiceState(
        serviceTimeMs: Double,
        currentFrameRate: Int
    ) -> PFrameServiceState {
        let scale = frameIntervalMs(currentFrameRate: currentFrameRate) / (1_000.0 / 60.0)
        if serviceTimeMs <= Self.pFrameExcellentMsAt60FPS * scale { return .excellent }
        if serviceTimeMs <= Self.pFrameAcceptableMsAt60FPS * scale { return .acceptable }
        if serviceTimeMs <= Self.pFrameSlowMsAt60FPS * scale { return .slow }
        if serviceTimeMs <= Self.pFrameBadMsAt60FPS * scale { return .bad }
        return .severe
    }

    private func learnedSafePFrameWireBytes(
        sample: HostPFrameSendSample,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Int {
        let targetClearMs = targetClearMs(currentFrameRate: currentFrameRate)
        let serviceMs = max(0.001, sample.serviceTimeMs)
        let learned = Int((Double(max(1, sample.wireBytes)) / serviceMs * targetClearMs * Self.learnedThroughputUtilization)
            .rounded(.down))
        return clampCeilingWireBytes(learned, input: input, currentFrameRate: currentFrameRate)
    }

    private func isThroughputLearningSample(
        _ sample: HostPFrameSendSample,
        currentFrameRate: Int
    ) -> Bool {
        let fpsScale = 60.0 / Double(max(1, currentFrameRate))
        let minimumWireBytes = Int((Double(Self.minimumThroughputLearningWireBytesAt60FPS) * fpsScale).rounded(.up))
        return sample.wireBytes >= minimumWireBytes
    }

    private func minimumLatencyOnlyCeilingWireBytes(
        input: BudgetInput,
        currentFrameRate: Int
    ) -> Int {
        let fpsScale = 60.0 / Double(max(1, currentFrameRate))
        let wireBytes = Int((Double(Self.minimumLatencyOnlyCeilingWireBytesAt60FPS) * fpsScale).rounded(.up))
        return clampCeilingWireBytes(wireBytes, input: input, currentFrameRate: currentFrameRate)
    }

    private mutating func recordEligibleServiceState(_ state: PFrameServiceState) {
        recentEligibleServiceStates.append(state)
        if recentEligibleServiceStates.count > Self.recentEligibleServiceStateLimit {
            recentEligibleServiceStates.removeFirst(
                recentEligibleServiceStates.count - Self.recentEligibleServiceStateLimit
            )
        }
    }

    private func logCapacitySampleDecision(
        sample: HostPFrameSendSample,
        serviceState: PFrameServiceState,
        currentFrameRate: Int,
        accepted: Bool,
        quarantineReason: String?,
        oldCeiling: Int,
        newCeiling: Int
    ) {
        let latency = sample.serviceTimeMs.formatted(.number.precision(.fractionLength(2)))
        let oldKB = (Double(oldCeiling) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let newKB = (Double(newCeiling) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let sampleKB = (Double(sample.wireBytes) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "event=p_frame_capacity_sample frame=\(sample.frameNumber) wireBytes=\(sampleKB)KB " +
                "packets=\(sample.packetCount) source=\(sample.timingSource) latencyMs=\(latency) " +
                "state=\(serviceState) receiverHealthy=\(sample.receiverHealthy) accepted=\(accepted) " +
                "quarantine=\(quarantineReason ?? "none") oldCeiling=\(oldKB)KB newCeiling=\(newKB)KB " +
                "bitrate=\(bitrateForWireBytes(newCeiling, currentFrameRate: currentFrameRate))"
        )
    }

    private mutating func initializeCeilingIfNeeded(
        _ input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) {
        guard transportCeilingWireBytes == nil else { return }
        let fpsScale = 60.0 / Double(max(1, currentFrameRate))
        let initialOperatingTarget = Int((Double(Self.localWiFiInitialOperatingTargetAt60FPS) * fpsScale).rounded(.up))
        let initialCeiling = Int((Double(initialOperatingTarget) / Self.operatingTargetRatio).rounded(.up))
        setTransportCeilingWireBytes(
            initialCeiling,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func budgetInput(
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int
    ) -> BudgetInput {
        let current = [currentBitrateBps, requestedTargetBitrateBps, startupCeilingBps]
            .compactMap { $0 }
            .filter { $0 > 0 }
            .first ?? 1
        let maximum = max(current, startupCeilingBps ?? current, requestedTargetBitrateBps ?? current)
        return BudgetInput(
            currentBitrate: max(1, current),
            maximumCeiling: max(1, maximum),
            floor: max(1, minimumBitrateFloorBps)
        )
    }

    private mutating func setTransportCeilingWireBytes(
        _ wireBytes: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) {
        let clamped = clampCeilingWireBytes(wireBytes, input: input, currentFrameRate: currentFrameRate)
        transportCeilingWireBytes = clamped
        operatingTargetWireBytes = max(1, Int((Double(clamped) * Self.operatingTargetRatio).rounded(.down)))
        burstLimitWireBytes = max(operatingTargetWireBytes ?? 1, Int((Double(clamped) * Self.burstLimitRatio).rounded(.down)))
        runtimeCeilingBps = bitrateForWireBytes(clamped, currentFrameRate: currentFrameRate)
        _ = maxPayloadSize
    }

    private func clampCeilingWireBytes(
        _ wireBytes: Int,
        input: BudgetInput,
        currentFrameRate: Int
    ) -> Int {
        let floorBytes = max(
            Self.minimumCeilingWireBytes,
            wireBytesForBitrate(input.floor, currentFrameRate: currentFrameRate)
        )
        let maxBytes = wireBytesForBitrate(input.maximumCeiling, currentFrameRate: currentFrameRate)
        return min(maxBytes, max(floorBytes, wireBytes))
    }

    private func currentCeilingWireBytes(input: BudgetInput, currentFrameRate: Int) -> Int {
        transportCeilingWireBytes ?? clampCeilingWireBytes(
            wireBytesForBitrate(input.currentBitrate, currentFrameRate: currentFrameRate),
            input: input,
            currentFrameRate: currentFrameRate
        )
    }

    private func currentOperatingTargetWireBytes(input: BudgetInput, currentFrameRate: Int) -> Int {
        operatingTargetWireBytes ?? max(
            1,
            Int((Double(currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)) * Self.operatingTargetRatio)
                .rounded(.down))
        )
    }

    private func pFrameBudget(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        now: CFAbsoluteTime
    ) -> PFrameBudget {
        let ceiling = currentCeilingWireBytes(input: input, currentFrameRate: currentFrameRate)
        let operating = operatingTargetWireBytes ?? max(1, Int((Double(ceiling) * Self.operatingTargetRatio).rounded(.down)))
        let burst = burstLimitWireBytes ?? max(operating, Int((Double(ceiling) * Self.burstLimitRatio).rounded(.down)))
        let payload = max(1, maxPayloadSize)
        let ceilingPackets = max(Self.minimumPacketCount, (ceiling + payload - 1) / payload)
        let operatingPackets = max(Self.minimumPacketCount, (operating + payload - 1) / payload)
        let burstPackets = max(operatingPackets, (burst + payload - 1) / payload)
        return PFrameBudget(
            ceilingWireBytes: ceiling,
            operatingTargetWireBytes: operating,
            burstLimitWireBytes: burst,
            ceilingPacketCount: ceilingPackets,
            operatingTargetPacketCount: operatingPackets,
            burstLimitPacketCount: burstPackets,
            sendDeadline: now + 1.0 / Double(max(1, currentFrameRate))
        )
    }

    private mutating func makeDecision(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        state: PressureState,
        reason: Reason,
        quality: Float,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let budget = pFrameBudget(input: input, currentFrameRate: currentFrameRate, maxPayloadSize: maxPayloadSize, now: now)
        let ceiling = runtimeQualityCeiling(steadyQualityCeiling: steadyQualityCeiling, state: state)
        let boundedQuality = max(qualityFloor, min(ceiling, quality))
        latestState = state
        latestReason = reason
        latestDecisionTime = now
        return HostFrameBudgetDecision(
            targetBitrateBps: bitrateForWireBytes(budget.ceilingWireBytes, currentFrameRate: currentFrameRate),
            maxFrameBytes: budget.ceilingWireBytes,
            maxWireBytes: budget.ceilingWireBytes,
            maxPacketCount: budget.ceilingPacketCount,
            quality: boundedQuality,
            qualityCeiling: ceiling,
            keyframeQuality: max(0.02, min(boundedQuality * 0.70, ceiling * 0.70)),
            sendDeadline: budget.sendDeadline,
            state: state,
            reason: reason
        )
    }

    private func targetClearMs(currentFrameRate: Int) -> Double {
        Self.pFrameServiceTargetMsAt60FPS * frameIntervalMs(currentFrameRate: currentFrameRate) / (1_000.0 / 60.0)
    }

    private func frameIntervalMs(currentFrameRate: Int) -> Double {
        1_000.0 / Double(max(1, currentFrameRate))
    }

    private func wireBytesForBitrate(_ bitrate: Int, currentFrameRate: Int) -> Int {
        max(1, Int((Double(max(1, bitrate)) / 8.0 / Double(max(1, currentFrameRate))).rounded(.down)))
    }

    private func bitrateForWireBytes(_ wireBytes: Int, currentFrameRate: Int) -> Int {
        max(1, max(1, wireBytes) * 8 * max(1, currentFrameRate))
    }

    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 1 }
        let sortedValues = values.sorted()
        return sortedValues[sortedValues.count / 2]
    }

}
#endif
