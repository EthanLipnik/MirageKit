//
//  HostAdaptivePFrameController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
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
    let deliveryMs: Double
    let packetSpanMs: Double
    let completionGapMs: Double
    let completionAgeAtFeedbackMs: Double
    let firstPacketGapMs: Double
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
        case receiverFreshness = "receiver-freshness"
        case adaptiveRepair = "adaptive-repair"
    }

    private struct BudgetInput: Equatable {
        let currentBitrate: Int
        let requestedBitrate: Int
        let maximumCeiling: Int
        let floor: Int
    }

    private struct ModePolicy: Equatable {
        let targetClearMs: Double
        let staleSampleAgeMs: Double
        let passiveStaleFrameAgeMs: Double
        let startupFrameWireBytesAt60FPS: Int

        static func policy(for latencyMode: MirageStreamLatencyMode) -> ModePolicy {
            switch latencyMode {
            case .lowestLatency:
                ModePolicy(
                    targetClearMs: 14,
                    staleSampleAgeMs: 500,
                    passiveStaleFrameAgeMs: 80,
                    startupFrameWireBytesAt60FPS: 64 * 1024
                )
            case .balanced:
                ModePolicy(
                    targetClearMs: 33,
                    staleSampleAgeMs: 1_000,
                    passiveStaleFrameAgeMs: 250,
                    startupFrameWireBytesAt60FPS: 96 * 1024
                )
            case .smoothest:
                ModePolicy(
                    targetClearMs: 66,
                    staleSampleAgeMs: 1_000,
                    passiveStaleFrameAgeMs: 300,
                    startupFrameWireBytesAt60FPS: 128 * 1024
                )
            }
        }
    }

    private enum MotionClass: Equatable {
        case still
        case passive
        case input

        func ramp(from bytes: Int) -> Int {
            switch self {
            case .still:
                max(bytes + 8 * 1024, Int((Double(bytes) * 1.12).rounded(.up)))
            case .passive:
                max(bytes + 4 * 1024, Int((Double(bytes) * 1.06).rounded(.up)))
            case .input:
                max(bytes + 2 * 1024, Int((Double(bytes) * 1.035).rounded(.up)))
            }
        }

        func qualityStep(from quality: Float, ceiling: Float) -> Float {
            switch self {
            case .still:
                min(ceiling, max(quality + 0.035, quality * 1.08))
            case .passive:
                min(ceiling, max(quality + 0.025, quality * 1.05))
            case .input:
                min(ceiling, max(quality + 0.015, quality * 1.03))
            }
        }

        var cleanRaiseUtilizationLimit: Double {
            switch self {
            case .still:
                0.90
            case .passive:
                0.85
            case .input:
                0.75
            }
        }

        var sampledRaiseUtilizationLimit: Double {
            switch self {
            case .still:
                0.95
            case .passive:
                0.92
            case .input:
                0.88
            }
        }
    }

    private static let safeDeliveryUtilization = 0.90
    private static let receiverPanicCutScale = 0.45
    private static let senderDeadlineCutScale = 0.70
    private static let receiverFreshnessCutScale = 0.55
    private static let minimumFrameWireBytes = 6 * 1024
    private static let minimumPacketCount = 8
    private static let nearFloorTargetRatio = 1.25
    private static let nearFloorTargetPacketSlack = 2
    private static let nearFloorOversizeMinimumToleranceBytes = 18 * 1024
    private static let nearFloorOversizeTargetRatio = 1.65
    private static let nearFloorOversizePacketSlack = 6
    private static let nearFloorPressureTargetRatio = 1.60
    private static let pFrameSpikeBaselinePivotKB = 16.0
    private static let pFrameSpikeMaximumRatio = 3.5
    private static let pFrameSpikeMinimumRatio = 1.25
    private static let pFrameSpikeLogStepScale = 0.35
    private static let pFrameSpikePacketSlack = 8
    private static let minimumCapacityLearningWireBytes = 12 * 1024
    private static let minimumCleanBaselineWireBytes = 8 * 1024
    private static let catastrophicPFrameMinimumWireBytes = 4 * 1024 * 1024
    private static let catastrophicPFrameMinimumOvershootBytes = 2 * 1024 * 1024
    private static let catastrophicPFrameMinimumRatio = 2.0
    private static let catastrophicPFrameHeadroomRatio = 1.75
    private static let catastrophicPFramePredictedClearRatio = 1.75
    private static let catastrophicRepairTargetScale = 2.0 / 3.0
    private static let catastrophicRepairMaximumHeadroomScale = 2.0
    private static let catastrophicRepairMinimumSavingsRatio = 0.85
    private static let catastrophicRepairQualityScale = 2.0 / 3.0
    private static let recentFailureRaiseHeadroom = 0.82
    private static let maximumFailureProbeHeadroom = 0.98
    private static let failureProbeWindowSeconds: CFAbsoluteTime = 60.0
    private static let passiveFailureProbeWindowSeconds: CFAbsoluteTime = 3.0
    private static let stillFailureProbeBypassSeconds: CFAbsoluteTime = 0.25

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
    private(set) var holdDownUntil: CFAbsoluteTime = 0
    private(set) var qualityRaiseSuppressedUntil: CFAbsoluteTime = 0
    private(set) var lastAdmittedPFrameWireBytes: Int?
    private(set) var lastAdmittedPFramePacketCount: Int?
    private(set) var lastAdmittedPFrameQuality: Float?
    private(set) var adaptiveEpoch: UInt64 = 0

    private var targetFrameWireBytes: Int?
    private var learnedBytesPerMs: Double?
    private var lastReceiverDeliveryFrameNumber: UInt64?
    private var lastReceiverDeliveryFeedbackTime: CFAbsoluteTime = 0
    private var lastRaisedFrameWireBytes: Int?
    private var adaptiveEpochStartedAt: CFAbsoluteTime = 0
    private var receiverFailureFrameWireBytes: Int?
    private var receiverFailureSafeWireBytes: Int?
    private var lastReceiverPressureTime: CFAbsoluteTime = 0

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
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
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
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )

        let hasLoss = feedback.lostFrameCount > 0 || feedback.discardedPacketCount > 0
        let hasRecoveryPanic = feedback.recoveryState == .keyframeRecovery || feedback.recoveryState == .hardRecovery
        guard hasLoss || hasRecoveryPanic else { return nil }

        adaptiveEpoch &+= 1
        adaptiveEpochStartedAt = now
        let reason: Reason = hasLoss ? .receiverLoss : .clientRecovery
        let decision = cutBudget(
            scale: Self.receiverPanicCutScale,
            state: .severe,
            reason: reason,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            now: now
        )
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.50)
        return decision
    }

    mutating func evaluateEncodedFrame(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
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
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        now: CFAbsoluteTime
    ) -> HostEncodedFrameAdmissionDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        let policy = ModePolicy.policy(for: latencyMode)
        let targetBytes = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let packetTarget = packetCountForWireBytes(targetBytes, maxPayloadSize: maxPayloadSize)
        let sendDeadline = now + 1.0 / Double(max(1, currentFrameRate))
        let byteRatio = Double(max(0, byteCount)) / Double(max(1, targetBytes))
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, targetBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, packetTarget))

        if isKeyframe {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let predictedDeliveryMs = predictedDeliveryMs(
            wireBytes: wireBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        if predictedDeliveryMs <= policy.targetClearMs ||
            shouldTolerateNearFloorFrame(
                wireBytes: wireBytes,
                packetCount: packetCount,
                targetBytes: targetBytes,
                packetTarget: packetTarget,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            ) {
            recordAdmittedPFrame(
                wireBytes: wireBytes,
                packetCount: packetCount,
                quality: currentQuality,
                receiverHealthy: receiverHealthy,
                senderHealthy: senderHealthy
            )
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        if let repairTargetBytes = catastrophicPFrameRepairTargetWireBytes(
            wireBytes: wireBytes,
            packetCount: packetCount,
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            predictedDeliveryMs: predictedDeliveryMs,
            policy: policy,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        ) {
            recordPressureCeiling(
                failedTarget: max(targetBytes, wireBytes),
                safeTarget: repairTargetBytes,
                now: now
            )
            setTargetFrameWireBytes(
                repairTargetBytes,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            let repairQuality = max(
                qualityFloor,
                min(steadyQualityCeiling, currentQuality * Float(Self.catastrophicRepairQualityScale))
            )
            let decision = makeDecision(
                state: .recovery,
                reason: .adaptiveRepair,
                quality: repairQuality,
                keyframeQuality: repairQuality,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                now: now
            )
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.50)
            return HostEncodedFrameAdmissionDecision(
                admission: .dropPFrameStartChainRepair,
                budgetDecision: decision,
                sendDeadline: sendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }

        let cutScale = oversizeCutScale(targetClearMs: policy.targetClearMs, predictedDeliveryMs: predictedDeliveryMs)
        let nextBudget = min(
            targetBytes,
            Int((Double(targetBytes) * cutScale).rounded(.down)),
            safeFrameWireBytes(
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                latencyMode: latencyMode
            )
        )
        recordPressureCeiling(
            failedTarget: max(targetBytes, wireBytes),
            safeTarget: nextBudget,
            now: now
        )
        setTargetFrameWireBytes(
            nextBudget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let quality = max(qualityFloor, min(steadyQualityCeiling, currentQuality * Float(cutScale)))
        let decision = makeDecision(
            state: .pressured,
            reason: .encodedFrame,
            quality: quality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            now: now
        )
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)

        recordAdmittedPFrame(
            wireBytes: wireBytes,
            packetCount: packetCount,
            quality: currentQuality,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy
        )

        return HostEncodedFrameAdmissionDecision(
            admission: .sendWithQualityDrop,
            budgetDecision: decision,
            sendDeadline: sendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio
        )
    }

    mutating func recordFrameTransportCompletion(
        frameNumber: UInt64,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        sendCompletionMs: Double,
        packetSpanMs: Double? = nil,
        completionGapMs: Double? = nil,
        completionAgeAtFeedbackMs: Double? = nil,
        firstPacketGapMs: Double? = nil,
        timingSource: TimingSource = .localSendCompletion,
        receiverHealthy: Bool,
        capacityLearningAllowed: Bool = true,
        capacityLearningQuarantineReason: String? = nil,
        inputActive: Bool = false,
        sourceStill: Bool = false,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        guard !isKeyframe else { return nil }
        guard timingSource != .localSendCompletion else { return nil }
        guard capacityLearningAllowed else {
            if let capacityLearningQuarantineReason {
                latestReason = capacityLearningQuarantineReason == "local-send-completion"
                    ? latestReason
                    : .pFrameLatency
            }
            return nil
        }

        let policy = ModePolicy.policy(for: latencyMode)
        let sampleAgeMs = max(0, completionAgeAtFeedbackMs ?? 0)
        guard sampleAgeMs <= policy.staleSampleAgeMs else { return nil }
        if adaptiveEpochStartedAt > 0 {
            let approximateCompletionTime = now - sampleAgeMs / 1_000.0
            guard approximateCompletionTime >= adaptiveEpochStartedAt else { return nil }
        }
        if let lastReceiverDeliveryFrameNumber,
           !isFrameNumber(frameNumber, newerThan: lastReceiverDeliveryFrameNumber) {
            return nil
        }

        let currentTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let packetTarget = packetCountForWireBytes(currentTarget, maxPayloadSize: maxPayloadSize)
        let packetSpan = max(0, packetSpanMs ?? sendCompletionMs)
        let gap = max(0, completionGapMs ?? sendCompletionMs)
        let transportDeliveryMs = max(1, packetSpan)
        guard transportDeliveryMs.isFinite else { return nil }
        let sampleBytesPerMs = Double(max(1, wireBytes)) / max(1, transportDeliveryMs)

        lastReceiverDeliveryFrameNumber = frameNumber
        lastReceiverDeliveryFeedbackTime = now
        let sample = HostPFrameSendSample(
            frameNumber: frameNumber,
            wireBytes: wireBytes,
            packetCount: packetCount,
            deliveryMs: transportDeliveryMs,
            packetSpanMs: packetSpan,
            completionGapMs: gap,
            completionAgeAtFeedbackMs: sampleAgeMs,
            firstPacketGapMs: max(0, firstPacketGapMs ?? gap),
            timingSource: timingSource,
            receiverHealthy: receiverHealthy
        )
        if shouldLearnCapacity(
            wireBytes: wireBytes,
            currentTarget: currentTarget,
            packetCount: packetCount,
            currentPacketTarget: packetTarget
        ) || shouldLearnCleanUpwardCapacity(
            sampleBytesPerMs: sampleBytesPerMs,
            deliveryMs: transportDeliveryMs,
            targetClearMs: policy.targetClearMs,
            receiverHealthy: receiverHealthy
        ) {
            learnCapacity(
                from: sample,
                allowsDownwardLearning: !isNearPathFloor(
                    targetBytes: currentTarget,
                    packetTarget: packetTarget,
                    input: input,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize
                )
            )
        }
        updateCleanBaseline(from: sample)

        let safeBytes = safeFrameWireBytes(
            sampleBytesPerMs: sampleBytesPerMs,
            targetClearMs: policy.targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let pressureDeliveryMs = transportDeliveryMs
        if pressureDeliveryMs > policy.targetClearMs {
            if shouldTolerateNearFloorPressure(
                pressureDeliveryMs: pressureDeliveryMs,
                policy: policy,
                wireBytes: wireBytes,
                packetCount: packetCount,
                targetBytes: currentTarget,
                packetTarget: packetTarget,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            ) {
                return nil
            }
            let nextBudget = min(currentTarget, safeBytes)
            recordPressureCeiling(
                failedTarget: max(currentTarget, wireBytes),
                safeTarget: nextBudget,
                now: now
            )
            setTargetFrameWireBytes(
                nextBudget,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            let qualityScale = oversizeCutScale(
                targetClearMs: policy.targetClearMs,
                predictedDeliveryMs: pressureDeliveryMs
            )
            let quality = max(qualityFloor, min(steadyQualityCeiling, currentQuality * Float(qualityScale)))
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return makeDecision(
                state: pressureDeliveryMs > policy.targetClearMs * 1.8 ? .severe : .pressured,
                reason: .pFrameLatency,
                quality: quality,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                now: now
            )
        }

        guard receiverHealthy, now >= qualityRaiseSuppressedUntil else { return nil }
        let motionClass = motionClass(inputActive: inputActive, sourceStill: sourceStill)
        let predictedCurrentMs = predictedDeliveryMs(
            wireBytes: currentTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        let predictedDeliveryAllowsRaise = predictedCurrentMs <= policy.targetClearMs * motionClass.cleanRaiseUtilizationLimit
        let sampledDeliveryAllowsRaise = transportDeliveryMs <= policy.targetClearMs * motionClass.sampledRaiseUtilizationLimit
        guard predictedDeliveryAllowsRaise || sampledDeliveryAllowsRaise else { return nil }

        let raisedTarget = motionClass.ramp(from: currentTarget)
        let cappedRaisedTarget = min(
            raisedTarget,
            raiseCeilingLimit(
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                motionClass: motionClass,
                now: now
            )
        )
        guard cappedRaisedTarget > currentTarget else { return nil }
        setTargetFrameWireBytes(
            cappedRaisedTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        lastRaisedFrameWireBytes = cappedRaisedTarget
        return makeDecision(
            state: .observing,
            reason: .healthy,
            quality: motionClass.qualityStep(from: currentQuality, ceiling: steadyQualityCeiling),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            now: now
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
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        return cutBudget(
            scale: Self.senderDeadlineCutScale,
            state: .severe,
            reason: .senderDeadline,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
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
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        adaptiveEpoch &+= 1
        adaptiveEpochStartedAt = now
        return cutBudget(
            scale: Self.receiverFreshnessCutScale,
            state: .severe,
            reason: .receiverFreshness,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            now: now
        )
    }

    mutating func resetEncodedOvershootHistory() {
        lastAdmittedPFrameWireBytes = nil
        lastAdmittedPFramePacketCount = nil
        lastAdmittedPFrameQuality = nil
    }

    private mutating func cutBudget(
        scale: Double,
        state: PressureState,
        reason: Reason,
        quality: Float? = nil,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let currentTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        setTargetFrameWireBytes(
            Int((Double(currentTarget) * max(0.10, min(0.98, scale))).rounded(.down)),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let decisionQuality = quality ?? max(
            qualityFloor,
            min(steadyQualityCeiling, currentQuality * Float(max(0.10, min(0.98, scale))))
        )
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
        return makeDecision(
            state: state,
            reason: reason,
            quality: decisionQuality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            now: now
        )
    }

    private mutating func makeDecision(
        state: PressureState,
        reason: Reason,
        quality: Float,
        keyframeQuality: Float? = nil,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let targetBytes = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let packetCount = packetCountForWireBytes(targetBytes, maxPayloadSize: maxPayloadSize)
        let targetBitrate = bitrate(forFrameWireBytes: targetBytes, currentFrameRate: currentFrameRate)
        runtimeCeilingBps = targetBitrate
        transportCeilingWireBytes = targetBytes
        operatingTargetWireBytes = targetBytes
        burstLimitWireBytes = targetBytes
        latestState = state
        latestReason = reason
        latestDecisionTime = now

        let boundedQuality = max(0.0, min(steadyQualityCeiling, quality))
        let boundedKeyframeQuality = max(
            0.0,
            min(steadyQualityCeiling, keyframeQuality ?? max(boundedQuality, boundedQuality * 1.25))
        )
        let runtimeQualityCeiling = state == .observing
            ? steadyQualityCeiling
            : max(0.02, min(steadyQualityCeiling, boundedQuality * 1.08))
        return HostFrameBudgetDecision(
            targetBitrateBps: targetBitrate,
            maxFrameBytes: targetBytes,
            maxWireBytes: targetBytes,
            maxPacketCount: packetCount,
            quality: boundedQuality,
            qualityCeiling: runtimeQualityCeiling,
            keyframeQuality: boundedKeyframeQuality,
            sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
            state: state,
            reason: reason
        )
    }

    private mutating func initializeIfNeeded(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) {
        guard targetFrameWireBytes == nil else { return }
        let requestedBytes = wireBytes(
            forBitrate: min(input.currentBitrate, input.requestedBitrate),
            currentFrameRate: currentFrameRate
        )
        let initialBytes = min(
            requestedBytes,
            startupProbeFrameWireBytes(
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                latencyMode: latencyMode
            )
        )
        setTargetFrameWireBytes(
            initialBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let policy = ModePolicy.policy(for: latencyMode)
        learnedBytesPerMs = Double(max(1, targetFrameWireBytes ?? initialBytes)) / max(1, policy.targetClearMs)
    }

    private func startupProbeFrameWireBytes(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        let policy = ModePolicy.policy(for: latencyMode)
        let fpsScale = 60.0 / Double(max(1, currentFrameRate))
        let startupBytes = Int((Double(policy.startupFrameWireBytesAt60FPS) * fpsScale).rounded(.up))
        return clampFrameWireBytes(
            startupBytes,
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
        let requested = max(1, requestedTargetBitrateBps ?? currentBitrateBps ?? startupCeilingBps ?? minimumBitrateFloorBps)
        let current = max(1, currentBitrateBps ?? requested)
        let ceiling = max(current, requested, startupCeilingBps ?? requested, minimumBitrateFloorBps)
        return BudgetInput(
            currentBitrate: max(minimumBitrateFloorBps, current),
            requestedBitrate: max(minimumBitrateFloorBps, requested),
            maximumCeiling: ceiling,
            floor: max(1, minimumBitrateFloorBps)
        )
    }

    private mutating func setTargetFrameWireBytes(
        _ bytes: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) {
        let clamped = clampFrameWireBytes(
            bytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        targetFrameWireBytes = clamped
        runtimeCeilingBps = bitrate(forFrameWireBytes: clamped, currentFrameRate: currentFrameRate)
        transportCeilingWireBytes = clamped
        operatingTargetWireBytes = clamped
        burstLimitWireBytes = clamped
    }

    private mutating func recordPressureCeiling(
        failedTarget: Int,
        safeTarget: Int,
        now: CFAbsoluteTime
    ) {
        let failedBytes = max(1, failedTarget)
        if let existing = receiverFailureFrameWireBytes,
           now - lastReceiverPressureTime <= 2.0 {
            receiverFailureFrameWireBytes = max(existing, failedBytes)
        } else {
            receiverFailureFrameWireBytes = failedBytes
        }
        receiverFailureSafeWireBytes = max(1, safeTarget)
        lastReceiverPressureTime = now
    }

    private func raiseCeilingLimit(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        motionClass: MotionClass,
        now: CFAbsoluteTime
    ) -> Int {
        let maximum = clampFrameWireBytes(
            wireBytes(forBitrate: input.maximumCeiling, currentFrameRate: currentFrameRate),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        guard let failureBytes = receiverFailureFrameWireBytes,
              lastReceiverPressureTime > 0 else {
            return maximum
        }
        let elapsed = max(0, now - lastReceiverPressureTime)
        switch motionClass {
        case .still:
            if elapsed >= Self.stillFailureProbeBypassSeconds {
                return maximum
            }
        case .passive:
            if elapsed >= Self.passiveFailureProbeWindowSeconds {
                return maximum
            }
        case .input:
            break
        }
        let probeWindow = motionClass == .input
            ? Self.failureProbeWindowSeconds
            : Self.passiveFailureProbeWindowSeconds
        let probeProgress = min(1.0, elapsed / probeWindow)
        let endHeadroom = motionClass == .input ? Self.maximumFailureProbeHeadroom : 1.10
        let headroom = Self.recentFailureRaiseHeadroom +
            (endHeadroom - Self.recentFailureRaiseHeadroom) * probeProgress
        let failureLimitedBytes = Int((Double(failureBytes) * headroom).rounded(.down))
        let safeBytes = receiverFailureSafeWireBytes ?? 0
        return min(maximum, max(safeBytes, failureLimitedBytes))
    }

    private func currentTargetFrameWireBytes(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Int {
        clampFrameWireBytes(
            targetFrameWireBytes ?? wireBytes(forBitrate: input.currentBitrate, currentFrameRate: currentFrameRate),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func clampFrameWireBytes(
        _ bytes: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Int {
        let floorBytes = max(
            Self.minimumFrameWireBytes,
            wireBytes(forBitrate: input.floor, currentFrameRate: currentFrameRate)
        )
        let ceilingBytes = max(
            floorBytes,
            wireBytes(forBitrate: input.maximumCeiling, currentFrameRate: currentFrameRate)
        )
        let packetFloor = max(
            Self.minimumPacketCount,
            packetCountForWireBytes(floorBytes, maxPayloadSize: maxPayloadSize)
        )
        let packetFloorBytes = packetFloor * max(1, maxPayloadSize)
        return max(floorBytes, min(max(bytes, packetFloorBytes), ceilingBytes))
    }

    private func wireBytes(forBitrate bitrate: Int, currentFrameRate: Int) -> Int {
        max(Self.minimumFrameWireBytes, Int((Double(max(1, bitrate)) / 8.0 / Double(max(1, currentFrameRate))).rounded(.up)))
    }

    private func bitrate(forFrameWireBytes wireBytes: Int, currentFrameRate: Int) -> Int {
        max(1, Int((Double(max(1, wireBytes)) * Double(max(1, currentFrameRate)) * 8.0).rounded(.up)))
    }

    private func packetCountForWireBytes(_ wireBytes: Int, maxPayloadSize: Int) -> Int {
        max(Self.minimumPacketCount, Int((Double(max(1, wireBytes)) / Double(max(1, maxPayloadSize))).rounded(.up)))
    }

    private func predictedDeliveryMs(
        wireBytes: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Double {
        let learned = learnedBytesPerMs ?? defaultBytesPerMs(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        return Double(max(1, wireBytes)) / max(1, learned)
    }

    private func defaultBytesPerMs(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Double {
        let policy = ModePolicy.policy(for: latencyMode)
        let target = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        return Double(max(1, target)) / max(1, policy.targetClearMs)
    }

    private func safeFrameWireBytes(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int {
        let policy = ModePolicy.policy(for: latencyMode)
        let learned = learnedBytesPerMs ?? defaultBytesPerMs(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        return safeFrameWireBytes(
            sampleBytesPerMs: learned,
            targetClearMs: policy.targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func safeFrameWireBytes(
        sampleBytesPerMs: Double,
        targetClearMs: Double,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Int {
        clampFrameWireBytes(
            Int((sampleBytesPerMs * targetClearMs * Self.safeDeliveryUtilization).rounded(.down)),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func oversizeCutScale(targetClearMs: Double, predictedDeliveryMs: Double) -> Double {
        max(0.10, min(0.98, targetClearMs / max(1, predictedDeliveryMs) * Self.safeDeliveryUtilization))
    }

    private func catastrophicPFrameRepairTargetWireBytes(
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        predictedDeliveryMs: Double,
        policy: ModePolicy,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode
    ) -> Int? {
        let overshootBytes = wireBytes - targetBytes
        guard wireBytes >= Self.catastrophicPFrameMinimumWireBytes,
              overshootBytes >= Self.catastrophicPFrameMinimumOvershootBytes else {
            return nil
        }

        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, targetBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, packetTarget))
        guard wireRatio >= Self.catastrophicPFrameMinimumRatio ||
              packetRatio >= Self.catastrophicPFrameMinimumRatio else {
            return nil
        }

        let safeBytes = safeFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        let headroomBytes = max(targetBytes, safeBytes)
        guard wireBytes > Int((Double(headroomBytes) * Self.catastrophicPFrameHeadroomRatio).rounded(.up)),
              predictedDeliveryMs > policy.targetClearMs * Self.catastrophicPFramePredictedClearRatio else {
            return nil
        }

        let repairTarget = min(
            Double(wireBytes) * Self.catastrophicRepairTargetScale,
            Double(headroomBytes) * Self.catastrophicRepairMaximumHeadroomScale
        )
        let clampedRepairTarget = clampFrameWireBytes(
            Int(repairTarget.rounded(.up)),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        guard clampedRepairTarget <= Int((Double(wireBytes) * Self.catastrophicRepairMinimumSavingsRatio).rounded(.down)) else {
            return nil
        }
        return clampedRepairTarget
    }

    private mutating func learnCapacity(
        from sample: HostPFrameSendSample,
        allowsDownwardLearning: Bool
    ) {
        let sampleBytesPerMs = Double(max(1, sample.wireBytes)) / max(1, sample.deliveryMs)
        guard sampleBytesPerMs.isFinite, sampleBytesPerMs > 0 else { return }
        if let learnedBytesPerMs {
            guard sampleBytesPerMs >= learnedBytesPerMs || allowsDownwardLearning else { return }
            let alpha = sampleBytesPerMs < learnedBytesPerMs ? 0.55 : 0.18
            self.learnedBytesPerMs = learnedBytesPerMs * (1 - alpha) + sampleBytesPerMs * alpha
        } else {
            learnedBytesPerMs = sampleBytesPerMs
        }
    }

    private mutating func updateCleanBaseline(from sample: HostPFrameSendSample) {
        guard sample.receiverHealthy else { return }
        guard isMeaningfulCleanBaselineSample(wireBytes: sample.wireBytes) else { return }
        if let baseline = recentCleanPFrameBaselineWireBytes {
            recentCleanPFrameBaselineWireBytes = Int((Double(baseline) * 0.80 + Double(sample.wireBytes) * 0.20).rounded())
        } else {
            recentCleanPFrameBaselineWireBytes = sample.wireBytes
        }
        if let baselinePackets = recentCleanPFrameBaselinePacketCount {
            recentCleanPFrameBaselinePacketCount = Int((Double(baselinePackets) * 0.80 + Double(sample.packetCount) * 0.20).rounded())
        } else {
            recentCleanPFrameBaselinePacketCount = sample.packetCount
        }
    }

    private mutating func recordAdmittedPFrame(
        wireBytes: Int,
        packetCount: Int,
        quality: Float,
        receiverHealthy: Bool,
        senderHealthy: Bool
    ) {
        lastAdmittedPFrameWireBytes = wireBytes
        lastAdmittedPFramePacketCount = packetCount
        lastAdmittedPFrameQuality = quality
        guard receiverHealthy, senderHealthy else { return }
        guard isMeaningfulCleanBaselineSample(wireBytes: wireBytes) else { return }
        if let baseline = recentCleanPFrameBaselineWireBytes {
            recentCleanPFrameBaselineWireBytes = Int((Double(baseline) * 0.90 + Double(wireBytes) * 0.10).rounded())
        } else {
            recentCleanPFrameBaselineWireBytes = wireBytes
        }
        if let baselinePackets = recentCleanPFrameBaselinePacketCount {
            recentCleanPFrameBaselinePacketCount = Int((Double(baselinePackets) * 0.90 + Double(packetCount) * 0.10).rounded())
        } else {
            recentCleanPFrameBaselinePacketCount = packetCount
        }
    }

    private func shouldLearnCapacity(
        wireBytes: Int,
        currentTarget: Int,
        packetCount: Int,
        currentPacketTarget: Int
    ) -> Bool {
        guard wireBytes >= Self.minimumCapacityLearningWireBytes else { return false }
        return wireBytes >= Int((Double(currentTarget) * 0.50).rounded(.up)) ||
            packetCount >= max(Self.minimumPacketCount, currentPacketTarget / 2)
    }

    private func shouldLearnCleanUpwardCapacity(
        sampleBytesPerMs: Double,
        deliveryMs: Double,
        targetClearMs: Double,
        receiverHealthy: Bool
    ) -> Bool {
        guard receiverHealthy,
              sampleBytesPerMs.isFinite,
              sampleBytesPerMs > 0,
              deliveryMs <= targetClearMs else {
            return false
        }
        guard let learnedBytesPerMs else { return true }
        return sampleBytesPerMs > learnedBytesPerMs
    }

    private func shouldTolerateNearFloorFrame(
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Bool {
        guard isNearPathFloor(
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        ) else {
            return false
        }
        let toleratedBytes = max(
            Self.nearFloorOversizeMinimumToleranceBytes,
            Int((Double(max(1, targetBytes)) * Self.nearFloorOversizeTargetRatio).rounded(.up))
        )
        let toleratedPackets = max(Self.minimumPacketCount, packetTarget + Self.nearFloorOversizePacketSlack)
        return wireBytes <= toleratedBytes && packetCount <= toleratedPackets
    }

    private func shouldTolerateNearFloorPressure(
        pressureDeliveryMs: Double,
        policy: ModePolicy,
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Bool {
        guard pressureDeliveryMs <= policy.targetClearMs * Self.nearFloorPressureTargetRatio else {
            return false
        }
        return shouldTolerateNearFloorFrame(
            wireBytes: wireBytes,
            packetCount: packetCount,
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func isNearPathFloor(
        targetBytes: Int,
        packetTarget: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Bool {
        let floorBytes = clampFrameWireBytes(
            0,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let floorPackets = packetCountForWireBytes(floorBytes, maxPayloadSize: maxPayloadSize)
        let nearFloorBytes = max(
            floorBytes + maxPayloadSize * Self.nearFloorTargetPacketSlack,
            Int((Double(floorBytes) * Self.nearFloorTargetRatio).rounded(.up))
        )
        return targetBytes <= nearFloorBytes &&
            packetTarget <= floorPackets + Self.nearFloorTargetPacketSlack
    }

    private func isMeaningfulCleanBaselineSample(wireBytes: Int) -> Bool {
        wireBytes >= Self.minimumCleanBaselineWireBytes
    }

    private func motionClass(inputActive: Bool, sourceStill: Bool) -> MotionClass {
        if inputActive {
            return .input
        }
        if sourceStill {
            return .still
        }
        return .passive
    }

    private func isFrameNumber(_ frameNumber: UInt64, newerThan current: UInt64) -> Bool {
        let difference = frameNumber &- current
        return difference != 0 && difference < 0x8000_0000_0000_0000
    }
}

#endif
