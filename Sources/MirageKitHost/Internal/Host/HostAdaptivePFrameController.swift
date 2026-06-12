//
//  HostAdaptivePFrameController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
//

import CoreFoundation
import CoreGraphics
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

struct HostPFrameTimingPressureSignal: Sendable, Equatable {
    let frameNumber: UInt64
    let deliveryMs: Double
    let packetSpanMs: Double
    let completionGapMs: Double
    let firstPacketGapMs: Double
    let targetClearMs: Double
    let reason: HostAdaptivePFrameController.Reason
}

struct HostEncodedFrameAdmissionDecision: Sendable, Equatable {
    let admission: HostEncodedFrameAdmission
    let budgetDecision: HostFrameBudgetDecision?
    let sendDeadline: CFAbsoluteTime
    let byteRatio: Double
    let wireRatio: Double
    let packetRatio: Double
    let deliveryMode: HostFrameDeliveryMode
    let requiredBitrateBps: Int?

    init(
        admission: HostEncodedFrameAdmission,
        budgetDecision: HostFrameBudgetDecision?,
        sendDeadline: CFAbsoluteTime,
        byteRatio: Double,
        wireRatio: Double,
        packetRatio: Double,
        deliveryMode: HostFrameDeliveryMode = .realtime,
        requiredBitrateBps: Int? = nil
    ) {
        self.admission = admission
        self.budgetDecision = budgetDecision
        self.sendDeadline = sendDeadline
        self.byteRatio = byteRatio
        self.wireRatio = wireRatio
        self.packetRatio = packetRatio
        self.deliveryMode = deliveryMode
        self.requiredBitrateBps = requiredBitrateBps
    }

    var isOverBudget: Bool {
        byteRatio > 1.0 || wireRatio > 1.0 || packetRatio > 1.0
    }
}

struct HostPFrameViabilitySnapshot: Sendable, Equatable {
    let observedP95WireBytes: Int
    let requiredBitrateBps: Int
}

struct HostPFrameViabilityController: Sendable, Equatable {
    private struct BucketKey: Sendable, Equatable, Hashable {
        let deliveryMode: HostFrameDeliveryMode
        let qualityBucket: Int
        let widthBucket: Int
        let heightBucket: Int
        let fps: Int
        let path: MirageMediaPathProfile
    }

    private struct Bucket: Sendable, Equatable {
        var samples: [Int] = []

        mutating func record(_ wireBytes: Int) {
            samples.append(max(1, wireBytes))
            if samples.count > HostPFrameViabilityController.maximumSamplesPerBucket {
                samples.removeFirst(samples.count - HostPFrameViabilityController.maximumSamplesPerBucket)
            }
        }

        var p95: Int? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))
            return sorted[index]
        }
    }

    private static let maximumSamplesPerBucket = 24

    private var buckets: [BucketKey: Bucket] = [:]

    mutating func record(
        wireBytes: Int,
        deliveryMode: HostFrameDeliveryMode,
        quality: Float,
        encodedSize: CGSize,
        frameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> HostPFrameViabilitySnapshot {
        let key = BucketKey(
            deliveryMode: deliveryMode,
            qualityBucket: Self.qualityBucket(quality),
            widthBucket: Self.dimensionBucket(encodedSize.width),
            heightBucket: Self.dimensionBucket(encodedSize.height),
            fps: max(1, frameRate),
            path: mediaPathProfile
        )
        var bucket = buckets[key] ?? Bucket()
        bucket.record(wireBytes)
        buckets[key] = bucket
        let p95 = bucket.p95 ?? max(1, wireBytes)
        return HostPFrameViabilitySnapshot(
            observedP95WireBytes: p95,
            requiredBitrateBps: Self.requiredBitrateBps(
                p95WireBytes: p95,
                observedFPS: frameRate,
                deliveryMode: deliveryMode,
                mediaPathProfile: mediaPathProfile
            )
        )
    }

    static func requiredBitrateBps(
        p95WireBytes: Int,
        observedFPS: Int,
        deliveryMode: HostFrameDeliveryMode,
        mediaPathProfile: MirageMediaPathProfile,
        targetClearMs: Double? = nil
    ) -> Int {
        let bytes = Double(max(1, p95WireBytes))
        let fps = Double(max(1, observedFPS))
        let clearSeconds = max(0.001, (targetClearMs ?? targetClearMilliseconds(
            deliveryMode: deliveryMode,
            mediaPathProfile: mediaPathProfile
        )) / 1_000.0)
        let averageFitBps = bytes * 8.0 * fps
        let clearFitBps = bytes * 8.0 / clearSeconds
        let utilization = deliveryUtilization(mediaPathProfile: mediaPathProfile)
        return Int((max(averageFitBps, clearFitBps) / utilization).rounded(.up))
    }

    static func targetClearMilliseconds(
        deliveryMode: HostFrameDeliveryMode,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Double {
        switch deliveryMode {
        case .lowMotionRamp:
            return mediaPathProfile.usesAwdlRadioPolicy ? 120.0 : 350.0
        case .recovery:
            return 120.0
        case .realtime:
            return 33.0
        }
    }

    private static func deliveryUtilization(mediaPathProfile: MirageMediaPathProfile) -> Double {
        if mediaPathProfile.usesAwdlRadioPolicy { return 0.65 }
        switch mediaPathProfile {
        case .localWiFi, .wired, .proximityWiredLike:
            return 0.85
        case .vpnOrOverlay:
            return 0.78
        case .other, .unknown, .awdlRadio:
            return 0.78
        }
    }

    private static func qualityBucket(_ quality: Float) -> Int {
        Int((Double(max(0, min(1, quality))) * 20.0).rounded(.down))
    }

    private static func dimensionBucket(_ value: CGFloat) -> Int {
        Int((max(1, value) / 128.0).rounded(.toNearestOrAwayFromZero))
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
        case transportBacklog = "transport-backlog"
        case encoderLag = "encoder-lag"
        case adaptiveRepair = "adaptive-repair"
        case motionOnset = "motion-onset"
    }

    private struct BudgetInput: Equatable {
        let currentBitrate: Int
        let requestedBitrate: Int
        let maximumCeiling: Int
        let floor: Int
        let usesOptimizedVPNProfile: Bool
    }

    private struct VPNReadableQualityTimingPolicy: Equatable {
        let target: Float
        let lowerBound: Float
        let maximumTimingScale: Double
        let maximumSendDeadlineMs: Double
    }

    private struct ModePolicy: Equatable {
        let targetClearMs: Double
        let staleSampleAgeMs: Double
        let passiveStaleFrameAgeMs: Double
        let startupFrameWireBytesAt60FPS: Int

        static func policy(
            for latencyMode: MirageStreamLatencyMode,
            mediaPathProfile: MirageMediaPathProfile = .unknown,
            receiverPlayoutDelayTargetMs: Double? = nil
        ) -> ModePolicy {
            if mediaPathProfile.usesAwdlRadioPolicy {
                let playoutTargetMs = receiverPlayoutDelayTargetMs.map {
                    min(MirageAwdlMediaController.maximumPlayoutDelayMs, max(MirageAwdlMediaController.minimumPlayoutDelayMs, $0))
                } ?? MirageAwdlMediaController.basePlayoutDelayMs
                let targetClearMs = max(50.0, playoutTargetMs)
                return ModePolicy(
                    targetClearMs: min(MirageAwdlMediaController.maximumPlayoutDelayMs, targetClearMs),
                    staleSampleAgeMs: 1_000,
                    passiveStaleFrameAgeMs: 300,
                    startupFrameWireBytesAt60FPS: 128 * 1024
                )
            }
            switch latencyMode {
            case .lowestLatency:
                return ModePolicy(
                    targetClearMs: HostAdaptivePFrameController.freshnessSoftHeadroomMs,
                    staleSampleAgeMs: 500,
                    passiveStaleFrameAgeMs: HostAdaptivePFrameController.freshnessPrecutHeadroomMs,
                    startupFrameWireBytesAt60FPS: 64 * 1024
                )
            case .balanced:
                return ModePolicy(
                    targetClearMs: HostAdaptivePFrameController.freshnessSoftHeadroomMs,
                    staleSampleAgeMs: HostAdaptivePFrameController.freshnessHardStaleFrameAgeMs,
                    passiveStaleFrameAgeMs: HostAdaptivePFrameController.freshnessPrecutHeadroomMs,
                    startupFrameWireBytesAt60FPS: 96 * 1024
                )
            case .smoothest:
                return ModePolicy(
                    targetClearMs: HostAdaptivePFrameController.freshnessSoftHeadroomMs,
                    staleSampleAgeMs: HostAdaptivePFrameController.freshnessHardStaleFrameAgeMs,
                    passiveStaleFrameAgeMs: HostAdaptivePFrameController.freshnessPrecutHeadroomMs,
                    startupFrameWireBytesAt60FPS: 128 * 1024
                )
            }
        }
    }

    private enum MotionClass: Equatable {
        case still
        case lowMotionRamp
        case passive
        case input

        func ramp(from bytes: Int) -> Int {
            switch self {
            case .still:
                max(bytes + 24 * 1024, Int((Double(bytes) * 1.35).rounded(.up)))
            case .lowMotionRamp:
                max(bytes + 16 * 1024, Int((Double(bytes) * 1.18).rounded(.up)))
            case .passive:
                max(bytes + 4 * 1024, Int((Double(bytes) * 1.06).rounded(.up)))
            case .input:
                max(bytes + 2 * 1024, Int((Double(bytes) * 1.035).rounded(.up)))
            }
        }

        func qualityStep(from quality: Float, ceiling: Float) -> Float {
            switch self {
            case .still:
                min(ceiling, max(quality + 0.08, quality * 1.20))
            case .lowMotionRamp:
                min(ceiling, max(quality + 0.045, quality * 1.09))
            case .passive:
                min(ceiling, max(quality + 0.025, quality * 1.05))
            case .input:
                min(ceiling, max(quality + 0.015, quality * 1.03))
            }
        }

        var cleanRaiseUtilizationLimit: Double {
            switch self {
            case .still:
                1.10
            case .lowMotionRamp:
                1.02
            case .passive:
                0.85
            case .input:
                0.75
            }
        }

        var sampledRaiseUtilizationLimit: Double {
            switch self {
            case .still:
                1.15
            case .lowMotionRamp:
                1.05
            case .passive:
                0.92
            case .input:
                0.88
            }
        }

        func headroomJumpCap(from bytes: Int) -> Int {
            switch self {
            case .still:
                Int((Double(bytes) * 2.00).rounded(.up))
            case .lowMotionRamp:
                Int((Double(bytes) * 1.50).rounded(.up))
            case .passive:
                Int((Double(bytes) * 1.25).rounded(.up))
            case .input:
                Int((Double(bytes) * 1.12).rounded(.up))
            }
        }
    }

    private static let safeDeliveryUtilization = 0.90
    private static let receiverPanicCutScale = 0.45
    private static let receiverRecoveryCutScale = 0.70
    private static let senderDeadlineCutScale = 0.70
    private static let receiverFreshnessCutScale = 0.55
    private static let transportBacklogCutScale = 0.78
    private static let cutCoalescingWindowSeconds: CFAbsoluteTime = 0.80
    private static let startupGraceMinimumCutScale = 0.70
    private static let headroomRaiseSafetyScale = 0.75
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
    private static let predictivePFrameOversizeTargetRatio = 1.18
    private static let predictivePFrameOversizePacketRatio = 1.15
    private static let predictivePFrameMinimumCutScale = 0.50
    private static let predictivePFrameMaximumCutScale = 0.92
    private static let motionGrowthPFrameMinimumWireBytes = 96 * 1024
    private static let motionGrowthPFrameWireRatio = 1.60
    private static let motionGrowthPFramePacketRatio = 1.45
    private static let motionGrowthPFrameMinimumCutScale = 0.58
    private static let motionGrowthPFrameMaximumCutScale = 0.86
    private static let receiverCadenceMotionGrowthMinimumWireBytes = 64 * 1024
    private static let receiverCadenceMotionGrowthMinimumDeltaBytes = 32 * 1024
    private static let receiverCadenceMotionGrowthWireRatio = 1.50
    private static let receiverCadenceMotionGrowthPacketRatio = 1.35
    private static let inputMotionBurstDropMinimumWireBytes = 256 * 1024
    private static let inputMotionBurstDropRatio = 1.55
    private static let passiveMotionBurstDropMinimumWireBytes = 512 * 1024
    private static let passiveMotionBurstDropRatio = 2.00
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
    private static let recentPassivePressureRaiseCooldownSeconds: CFAbsoluteTime = 0.20
    private static let recentInputPressureRaiseCooldownSeconds: CFAbsoluteTime = 0.30
    private static let stillFailureProbeBypassSeconds: CFAbsoluteTime = 0.25
    private static let freshnessPrecutHeadroomMs = 320.0
    private static let freshnessSoftHeadroomMs = 350.0
    private static let freshnessHardStaleFrameAgeMs = 500.0
    private static let inputMotionQualityTargetClearMs = 33.0
    private static let passiveMotionQualityTargetClearMs = 80.0
    private static let lowMotionQualityTargetClearMs = 33.0
    private static let lowMotionStillMaximumWireBytes = 192 * 1024
    private static let lowMotionStillBaselineRatio = 4.0
    private static let lowMotionStillBaselineSlackBytes = 48 * 1024
    private static let lowMotionStillBaselineMaximumWireBytes = 384 * 1024
    private static let vpnReadableQualityTarget: Float = 0.60
    private static let vpnReadableQualityLowerBound: Float = 0.50
    private static let vpnReadableQualityMaximumTimingScale = 1.45
    private static let vpnReadableQualityMaximumDeadlineFrames = 3.0
    private static let vpnReadableQualityMaximumSendDeadlineMs = 60.0
    private static let optimizedVPNReadableQualityTarget: Float = 0.75
    private static let optimizedVPNReadableQualityLowerBound: Float = 0.55
    private static let optimizedVPNReadableQualityMaximumTimingScale = 1.75
    private static let optimizedVPNReadableQualityMaximumSendDeadlineMs = 80.0
    private static let optimizedVPNTransientRuntimeQualityCeilingFloor: Float = 0.50
    private static let optimizedVPNSevereRuntimeQualityCeilingFloor: Float = 0.40
    private static let optimizedVPNProfileStartupBitratesBps: Set<Int> = [
        24_000_000,
        30_000_000,
        36_000_000,
    ]

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
    private(set) var latestRequiredBitrateForCurrentQualityBps: Int?
    private(set) var latestObservedPFrameWireBytesP95: Int?
    private(set) var latestDeliveryMode: HostFrameDeliveryMode = .realtime
    private(set) var holdDownUntil: CFAbsoluteTime = 0
    private(set) var qualityRaiseSuppressedUntil: CFAbsoluteTime = 0
    private(set) var lastAdmittedPFrameWireBytes: Int?
    private(set) var lastAdmittedPFramePacketCount: Int?
    private(set) var lastAdmittedPFrameQuality: Float?
    private(set) var adaptiveEpoch: UInt64 = 0
    private(set) var latestQualityGatedPFramePressure: HostPFrameTimingPressureSignal?

    private var targetFrameWireBytes: Int?
    private var learnedBytesPerMs: Double?
    private var lastReceiverDeliveryFrameNumber: UInt64?
    private var lastReceiverDeliveryFeedbackTime: CFAbsoluteTime = 0
    private var lastRaisedFrameWireBytes: Int?
    private var adaptiveEpochStartedAt: CFAbsoluteTime = 0
    private var receiverFailureFrameWireBytes: Int?
    private var receiverFailureSafeWireBytes: Int?
    private var lastReceiverPressureTime: CFAbsoluteTime = 0
    private var lastFeedbackLostFrameCount: UInt64?
    private var lastFeedbackDiscardedPacketCount: UInt64?
    private var lastFeedbackTransportTimeoutTotal: UInt64?
    private var lastPanicCutTime: CFAbsoluteTime = 0
    private var lastPanicCutReason: Reason?
    private var lastPanicCutPreTargetWireBytes: Int?
    private var startupGraceCutApplied = false
    private var viabilityController = HostPFrameViabilityController()

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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard feedback.sequence > latestFeedbackSequence else { return nil }
        latestFeedbackSequence = feedback.sequence
        let observedNewLoss = lastFeedbackLostFrameCount.map {
            feedback.lostFrameCount > $0
        } ?? false
        let observedNewDiscard = lastFeedbackDiscardedPacketCount.map {
            feedback.discardedPacketCount > $0
        } ?? false
        lastFeedbackLostFrameCount = feedback.lostFrameCount
        lastFeedbackDiscardedPacketCount = feedback.discardedPacketCount
        let transportTimeoutTotal = (feedback.reassemblerIncompleteFrameTimeouts ?? 0) &+
            (feedback.reassemblerMissingFragmentTimeouts ?? 0) &+
            (feedback.reassemblerForwardGapTimeouts ?? 0)
        let observedNewTransportTimeouts = lastFeedbackTransportTimeoutTotal.map {
            transportTimeoutTotal > $0
        } ?? false
        lastFeedbackTransportTimeoutTotal = transportTimeoutTotal

        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )

        let hasLoss = observedNewLoss || observedNewDiscard
        let hasRecoveryPanic = feedback.recoveryState == .keyframeRecovery || feedback.recoveryState == .hardRecovery
        guard hasLoss || hasRecoveryPanic else { return nil }
        guard frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        ) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return nil
        }

        // Recovery feedback alone is not congestion. A dynamic SCK source that goes
        // still makes the receiver's freeze monitor request keyframe recovery with no
        // packets lost; cutting on it collapses bitrate on perfectly healthy links.
        // Require fresh loss deltas or corroborating transport evidence in the same
        // feedback before treating recovery as a panic signal.
        let hasTransportEvidence = observedNewTransportTimeouts ||
            feedback.reassemblyBacklogFrames > 0 ||
            feedback.reassemblyBacklogBytes > 0 ||
            feedback.reliabilityCauses.contains(.forwardGapStall) ||
            feedback.reliabilityCauses.contains(.noProgressTimeout)
        guard hasLoss || hasTransportEvidence else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.50)
            return nil
        }

        adaptiveEpoch &+= 1
        adaptiveEpochStartedAt = now
        let severe = hasLoss || feedback.recoveryState == .hardRecovery
        let reason: Reason = hasLoss ? .receiverLoss : .clientRecovery
        let decision = cutBudget(
            scale: severe ? Self.receiverPanicCutScale : Self.receiverRecoveryCutScale,
            state: severe ? .severe : .pressured,
            reason: reason,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        deliveryMode: HostFrameDeliveryMode = .realtime,
        encodedSize: CGSize = .zero,
        now: CFAbsoluteTime
    ) -> HostEncodedFrameAdmissionDecision {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let targetBytes = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let packetTarget = packetCountForWireBytes(targetBytes, maxPayloadSize: maxPayloadSize)
        let baseSendDeadline = sendDeadline(
            now: now,
            currentFrameRate: currentFrameRate
        )
        let effectiveDeliveryMode = isKeyframe ? HostFrameDeliveryMode.recovery : deliveryMode
        latestDeliveryMode = effectiveDeliveryMode
        let viabilitySnapshot: HostPFrameViabilitySnapshot? = if isKeyframe {
            nil
        } else {
            viabilityController.record(
                wireBytes: wireBytes,
                deliveryMode: effectiveDeliveryMode,
                quality: currentQuality,
                encodedSize: encodedSize,
                frameRate: currentFrameRate,
                mediaPathProfile: mediaPathProfile
            )
        }
        latestRequiredBitrateForCurrentQualityBps = viabilitySnapshot?.requiredBitrateBps
        latestObservedPFrameWireBytesP95 = viabilitySnapshot?.observedP95WireBytes
        let byteRatio = Double(max(0, byteCount)) / Double(max(1, targetBytes))
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, targetBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, packetTarget))

        if isKeyframe {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: baseSendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio
            )
        }
        let sendDeadline = sendDeadline(
            now: now,
            currentFrameRate: currentFrameRate,
            currentQuality: currentQuality,
            input: input,
            mediaPathProfile: mediaPathProfile,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy
        )
        let effectiveSendDeadline = max(
            sendDeadline,
            lowMotionRampSendDeadline(
                now: now,
                deliveryMode: effectiveDeliveryMode,
                mediaPathProfile: mediaPathProfile
            )
        )

        let predictedDeliveryMs = predictedDeliveryMs(
            wireBytes: wireBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let qualityStillEnough = treatsFrameAsStillEnoughForQuality(
            inputActive: inputActive,
            sourceStill: sourceStill,
            wireBytes: wireBytes,
            packetCount: packetCount
        )
        var baseTargetClearMs = qualityTargetClearMs(
            policy: policy,
            inputActive: inputActive,
            sourceStill: sourceStill,
            stillEnough: qualityStillEnough,
            mediaPathProfile: mediaPathProfile
        )
        if effectiveDeliveryMode == .lowMotionRamp {
            baseTargetClearMs = max(
                baseTargetClearMs,
                HostPFrameViabilityController.targetClearMilliseconds(
                    deliveryMode: effectiveDeliveryMode,
                    mediaPathProfile: mediaPathProfile
                )
            )
        }
        let targetClearMs = timingTargetClearMs(
            baseTargetClearMs,
            currentQuality: currentQuality,
            input: input,
            mediaPathProfile: mediaPathProfile,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy
        )
        let nearFloorFrameTolerated = shouldTolerateNearFloorFrame(
            wireBytes: wireBytes,
            packetCount: packetCount,
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let canReduceFrameBudget = frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        )
        if predictedDeliveryMs <= targetClearMs || nearFloorFrameTolerated {
            if let viabilityDecision = lowMotionRampViabilityDecision(
                snapshot: viabilitySnapshot,
                deliveryMode: effectiveDeliveryMode,
                receiverHealthy: receiverHealthy,
                senderHealthy: senderHealthy,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                currentQuality: currentQuality,
                qualityFloor: qualityFloor,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                now: now
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
                    budgetDecision: viabilityDecision,
                    sendDeadline: effectiveSendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio,
                    deliveryMode: effectiveDeliveryMode,
                    requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
                )
            }
            if canReduceFrameBudget,
               !nearFloorFrameTolerated,
               let predictiveDecision = predictivePFrameOversizeDecision(
                   wireBytes: wireBytes,
                   packetCount: packetCount,
                   targetBytes: targetBytes,
                   packetTarget: packetTarget,
                   qualityStillEnough: qualityStillEnough,
                   sourceStill: sourceStill,
                   input: input,
                   currentFrameRate: currentFrameRate,
                   maxPayloadSize: maxPayloadSize,
                   currentQuality: currentQuality,
                   qualityFloor: qualityFloor,
                   steadyQualityCeiling: steadyQualityCeiling,
                   latencyMode: latencyMode,
                   mediaPathProfile: mediaPathProfile,
                   now: now
               ) {
                recordAdmittedPFrame(
                    wireBytes: wireBytes,
                    packetCount: packetCount,
                    quality: currentQuality,
                    receiverHealthy: receiverHealthy,
                    senderHealthy: senderHealthy,
                    updatesCleanBaseline: false
                )
                return HostEncodedFrameAdmissionDecision(
                    admission: .sendWithQualityDrop,
                    budgetDecision: predictiveDecision,
                    sendDeadline: effectiveSendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio,
                    deliveryMode: effectiveDeliveryMode,
                    requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
                )
            }
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
                sendDeadline: effectiveSendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                deliveryMode: effectiveDeliveryMode,
                requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
            )
        }

        let repairTargetBytes = catastrophicPFrameRepairTargetWireBytes(
            wireBytes: wireBytes,
            packetCount: packetCount,
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            predictedDeliveryMs: predictedDeliveryMs,
            targetClearMs: baseTargetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        if let repairTargetBytes {
            guard canReduceFrameBudget else {
                qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.50)
                return HostEncodedFrameAdmissionDecision(
                    admission: .dropPFrameStartChainRepair,
                    budgetDecision: nil,
                    sendDeadline: effectiveSendDeadline,
                    byteRatio: byteRatio,
                    wireRatio: wireRatio,
                    packetRatio: packetRatio,
                    deliveryMode: effectiveDeliveryMode,
                    requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
                )
            }
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
                mediaPathProfile: mediaPathProfile,
                now: now
            )
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.50)
            return HostEncodedFrameAdmissionDecision(
                admission: .dropPFrameStartChainRepair,
                budgetDecision: decision,
                sendDeadline: effectiveSendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                deliveryMode: effectiveDeliveryMode,
                requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
            )
        }

        let motionRepairTargetBytes = motionBurstPFrameRepairTargetWireBytes(
            wireBytes: wireBytes,
            packetCount: packetCount,
            targetBytes: targetBytes,
            packetTarget: packetTarget,
            predictedDeliveryMs: predictedDeliveryMs,
            targetClearMs: targetClearMs,
            inputActive: inputActive,
            sourceStill: sourceStill,
            qualityStillEnough: qualityStillEnough,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        if let motionRepairTargetBytes {
            recordPressureCeiling(
                failedTarget: max(targetBytes, wireBytes),
                safeTarget: motionRepairTargetBytes,
                now: now
            )
            setTargetFrameWireBytes(
                motionRepairTargetBytes,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            let qualityScale = oversizeCutScale(
                targetClearMs: targetClearMs,
                predictedDeliveryMs: predictedDeliveryMs
            )
            let quality = max(qualityFloor, min(steadyQualityCeiling, currentQuality * Float(qualityScale)))
            let decision = makeDecision(
                state: .recovery,
                reason: .encodedFrame,
                quality: quality,
                keyframeQuality: quality,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                now: now
            )
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.25)
            return HostEncodedFrameAdmissionDecision(
                admission: .dropPFrameStartChainRepair,
                budgetDecision: decision,
                sendDeadline: effectiveSendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                deliveryMode: effectiveDeliveryMode,
                requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
            )
        }

        if !canReduceFrameBudget {
            recordAdmittedPFrame(
                wireBytes: wireBytes,
                packetCount: packetCount,
                quality: currentQuality,
                receiverHealthy: receiverHealthy,
                senderHealthy: senderHealthy,
                updatesCleanBaseline: false
            )
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: effectiveSendDeadline,
                byteRatio: byteRatio,
                wireRatio: wireRatio,
                packetRatio: packetRatio,
                deliveryMode: effectiveDeliveryMode,
                requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
            )
        }

        let cutScale = oversizeCutScale(targetClearMs: targetClearMs, predictedDeliveryMs: predictedDeliveryMs)
        let nextBudget = min(
            targetBytes,
            Int((Double(targetBytes) * cutScale).rounded(.down)),
            safeFrameWireBytes(
                targetClearMs: targetClearMs,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
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
            mediaPathProfile: mediaPathProfile,
            now: now
        )
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)

        recordAdmittedPFrame(
            wireBytes: wireBytes,
            packetCount: packetCount,
            quality: currentQuality,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy,
            updatesCleanBaseline: false
        )

        return HostEncodedFrameAdmissionDecision(
            admission: .sendWithQualityDrop,
            budgetDecision: decision,
            sendDeadline: effectiveSendDeadline,
            byteRatio: byteRatio,
            wireRatio: wireRatio,
            packetRatio: packetRatio,
            deliveryMode: effectiveDeliveryMode,
            requiredBitrateBps: viabilitySnapshot?.requiredBitrateBps
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
        inputActive: Bool = false,
        sourceStill: Bool = false,
        deliveryMode: HostFrameDeliveryMode = .realtime,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        guard !isKeyframe else { return nil }
        guard timingSource != .localSendCompletion else { return nil }

        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let effectiveDeliveryMode = isKeyframe ? HostFrameDeliveryMode.recovery : deliveryMode
        latestDeliveryMode = effectiveDeliveryMode
        let viabilitySnapshot: HostPFrameViabilitySnapshot? = if isKeyframe {
            nil
        } else {
            viabilityController.record(
                wireBytes: wireBytes,
                deliveryMode: effectiveDeliveryMode,
                quality: currentQuality,
                encodedSize: .zero,
                frameRate: currentFrameRate,
                mediaPathProfile: mediaPathProfile
            )
        }
        latestRequiredBitrateForCurrentQualityBps = viabilitySnapshot?.requiredBitrateBps
        latestObservedPFrameWireBytesP95 = viabilitySnapshot?.observedP95WireBytes
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
        let firstPacketGap = max(0, firstPacketGapMs ?? gap)
        let transportDeliveryMs = max(1, packetSpan)
        guard transportDeliveryMs.isFinite else { return nil }
        let sampleBytesPerMs = Double(max(1, wireBytes)) / max(1, transportDeliveryMs)
        let qualityStillEnough = treatsFrameAsStillEnoughForQuality(
            inputActive: inputActive,
            sourceStill: sourceStill,
            wireBytes: wireBytes,
            packetCount: packetCount
        )
        let receiverMotionGrowthPressureRatio = receiverCadenceMotionGrowthPressureRatio(
            wireBytes: wireBytes,
            packetCount: packetCount,
            sourceStill: sourceStill
        )
        var baseTargetClearMs = qualityTargetClearMs(
            policy: policy,
            inputActive: inputActive,
            sourceStill: sourceStill,
            stillEnough: qualityStillEnough,
            mediaPathProfile: mediaPathProfile
        )
        if effectiveDeliveryMode == .lowMotionRamp {
            baseTargetClearMs = max(
                baseTargetClearMs,
                HostPFrameViabilityController.targetClearMilliseconds(
                    deliveryMode: effectiveDeliveryMode,
                    mediaPathProfile: mediaPathProfile
                )
            )
        }
        let targetClearMs = timingTargetClearMs(
            baseTargetClearMs,
            currentQuality: currentQuality,
            input: input,
            mediaPathProfile: mediaPathProfile,
            receiverHealthy: receiverHealthy,
            senderHealthy: true
        )

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
            firstPacketGapMs: firstPacketGap,
            timingSource: timingSource,
            receiverHealthy: receiverHealthy
        )
        if capacityLearningAllowed {
            if shouldLearnCapacity(
                wireBytes: wireBytes,
                currentTarget: currentTarget,
                packetCount: packetCount,
                currentPacketTarget: packetTarget
            ) || shouldLearnCleanUpwardCapacity(
                sampleBytesPerMs: sampleBytesPerMs,
                deliveryMs: transportDeliveryMs,
                targetClearMs: baseTargetClearMs,
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
        }

        let usesAwdlReceiverCadencePressure = mediaPathProfile.usesAwdlRadioPolicy &&
            !qualityStillEnough &&
            isMeaningfulCleanBaselineSample(wireBytes: wireBytes)
        let usesMotionReceiverCadencePressure = !mediaPathProfile.usesAwdlRadioPolicy &&
            receiverMotionGrowthPressureRatio != nil &&
            isMeaningfulCleanBaselineSample(wireBytes: wireBytes)
        let usesReceiverCadencePressure = usesAwdlReceiverCadencePressure || usesMotionReceiverCadencePressure
        let pressureDeliveryMs = usesReceiverCadencePressure
            ? max(transportDeliveryMs, gap, firstPacketGap)
            : transportDeliveryMs
        let pressureSampleBytesPerMs = usesReceiverCadencePressure
            ? Double(max(1, wireBytes)) / max(1, pressureDeliveryMs)
            : sampleBytesPerMs
        let safeBytes = safeFrameWireBytes(
            sampleBytesPerMs: pressureSampleBytesPerMs,
            targetClearMs: targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        if pressureDeliveryMs > targetClearMs {
            guard frameBudgetReductionAllowed(
                mediaPathProfile: mediaPathProfile,
                awdlQualityReductionAllowed: awdlQualityReductionAllowed
            ) else {
                if mediaPathProfile.usesAwdlRadioPolicy {
                    latestQualityGatedPFramePressure = HostPFrameTimingPressureSignal(
                        frameNumber: frameNumber,
                        deliveryMs: pressureDeliveryMs,
                        packetSpanMs: packetSpan,
                        completionGapMs: gap,
                        firstPacketGapMs: firstPacketGap,
                        targetClearMs: targetClearMs,
                        reason: .pFrameLatency
                    )
                }
                qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
                return nil
            }
            if shouldTolerateNearFloorPressure(
                pressureDeliveryMs: pressureDeliveryMs,
                targetClearMs: targetClearMs,
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
                targetClearMs: targetClearMs,
                predictedDeliveryMs: pressureDeliveryMs
            )
            let quality = max(qualityFloor, min(steadyQualityCeiling, currentQuality * Float(qualityScale)))
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return makeDecision(
                state: pressureDeliveryMs > targetClearMs * 1.8 ? .severe : .pressured,
                reason: .pFrameLatency,
                quality: quality,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                now: now
            )
        }

        if capacityLearningAllowed {
            updateCleanBaseline(from: sample)
        }

        guard capacityLearningAllowed,
              receiverHealthy,
              now >= qualityRaiseSuppressedUntil else { return nil }
        if let viabilityDecision = lowMotionRampViabilityDecision(
            snapshot: viabilitySnapshot,
            deliveryMode: effectiveDeliveryMode,
            receiverHealthy: receiverHealthy,
            senderHealthy: true,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        ) {
            return viabilityDecision
        }
        let motionClass = motionClass(
            inputActive: inputActive,
            sourceStill: sourceStill,
            deliveryMode: effectiveDeliveryMode
        )
        let predictedCurrentMs = predictedDeliveryMs(
            wireBytes: currentTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let predictedDeliveryAllowsRaise = predictedCurrentMs <= baseTargetClearMs * motionClass.cleanRaiseUtilizationLimit
        let sampledDeliveryAllowsRaise = transportDeliveryMs <= baseTargetClearMs * motionClass.sampledRaiseUtilizationLimit
        guard predictedDeliveryAllowsRaise || sampledDeliveryAllowsRaise else { return nil }

        let maximumTarget = maximumCeilingFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let classRaisedTarget = motionClass.ramp(from: currentTarget)
        let learnedSafeBytes = safeFrameWireBytes(
            targetClearMs: baseTargetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        // Proven capacity allows jumping past the per-sample class step (bounded per
        // class) so recovery from a deep cut converges in a few samples, not dozens.
        let headroomTarget = Int((Double(learnedSafeBytes) * Self.headroomRaiseSafetyScale).rounded(.down))
        let raisedTarget = max(
            classRaisedTarget,
            min(headroomTarget, motionClass.headroomJumpCap(from: currentTarget))
        )
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
        let raisedQuality = motionClass.qualityStep(from: currentQuality, ceiling: steadyQualityCeiling)
        let raiseCooldown = recentPressureRaiseCooldown(for: motionClass, now: now)
        guard cappedRaisedTarget > currentTarget else {
            guard cappedRaisedTarget == currentTarget,
                  currentTarget >= maximumTarget,
                  raisedQuality > currentQuality + 0.0001 else {
                return nil
            }
            if raiseCooldown > 0 {
                qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + raiseCooldown)
            }
            return makeDecision(
                state: .observing,
                reason: .healthy,
                quality: raisedQuality,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                steadyQualityCeiling: steadyQualityCeiling,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                now: now
            )
        }
        setTargetFrameWireBytes(
            cappedRaisedTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        lastRaisedFrameWireBytes = cappedRaisedTarget
        if raiseCooldown > 0 {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + raiseCooldown)
        }
        return makeDecision(
            state: .observing,
            reason: .healthy,
            quality: raisedQuality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        startupProtectionActive: Bool = false,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        ) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return nil
        }
        guard consumeStartupGraceCutAllowance(startupProtectionActive: startupProtectionActive) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.25)
            return nil
        }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        return cutBudget(
            scale: startupProtectionActive
                ? max(Self.senderDeadlineCutScale, Self.startupGraceMinimumCutScale)
                : Self.senderDeadlineCutScale,
            state: startupProtectionActive ? .pressured : .severe,
            reason: .senderDeadline,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        startupProtectionActive: Bool = false,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        ) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return nil
        }
        guard consumeStartupGraceCutAllowance(startupProtectionActive: startupProtectionActive) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.25)
            return nil
        }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        adaptiveEpoch &+= 1
        adaptiveEpochStartedAt = now
        return cutBudget(
            scale: startupProtectionActive
                ? max(Self.receiverFreshnessCutScale, Self.startupGraceMinimumCutScale)
                : Self.receiverFreshnessCutScale,
            state: startupProtectionActive ? .pressured : .severe,
            reason: .receiverFreshness,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    mutating func recordTransportBacklogPressure(
        severe: Bool,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        ) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return nil
        }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let scale = severe
            ? min(Self.transportBacklogCutScale, Self.receiverFreshnessCutScale)
            : Self.transportBacklogCutScale
        return cutBudget(
            scale: scale,
            state: severe ? .severe : .pressured,
            reason: .transportBacklog,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    mutating func recordEncoderTimingPressure(
        severe: Bool,
        cutScale: Double,
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        awdlQualityReductionAllowed: Bool = true,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard frameBudgetReductionAllowed(
            mediaPathProfile: mediaPathProfile,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed
        ) else {
            qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
            return nil
        }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        initializeIfNeeded(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        return cutBudget(
            scale: cutScale,
            state: severe ? .severe : .pressured,
            reason: .encoderLag,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: currentQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    mutating func resetEncodedOvershootHistory() {
        lastAdmittedPFrameWireBytes = nil
        lastAdmittedPFramePacketCount = nil
        lastAdmittedPFrameQuality = nil
    }

    mutating func consumeQualityGatedPFramePressure() -> HostPFrameTimingPressureSignal? {
        let signal = latestQualityGatedPFramePressure
        latestQualityGatedPFramePressure = nil
        return signal
    }

    mutating func retuneForFrameRateChange(
        from previousFrameRate: Int,
        to currentFrameRate: Int,
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        maxPayloadSize: Int,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) {
        let oldRate = max(1, previousFrameRate)
        let newRate = max(1, currentFrameRate)
        guard oldRate != newRate else { return }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        let frameRateScale = mediaPathProfile.usesAwdlRadioPolicy ? 1.0 : Double(oldRate) / Double(newRate)
        if let targetFrameWireBytes {
            setTargetFrameWireBytes(
                Int((Double(targetFrameWireBytes) * frameRateScale).rounded(.up)),
                input: input,
                currentFrameRate: newRate,
                maxPayloadSize: maxPayloadSize
            )
        }
        if let recentCleanPFrameBaselineWireBytes {
            let scaledBytes = Int((Double(recentCleanPFrameBaselineWireBytes) * frameRateScale).rounded(.up))
            self.recentCleanPFrameBaselineWireBytes = scaledBytes
            recentCleanPFrameBaselinePacketCount = packetCountForWireBytes(
                scaledBytes,
                maxPayloadSize: maxPayloadSize
            )
        }
        if let lastAdmittedPFrameWireBytes {
            let scaledBytes = Int((Double(lastAdmittedPFrameWireBytes) * frameRateScale).rounded(.up))
            self.lastAdmittedPFrameWireBytes = scaledBytes
            lastAdmittedPFramePacketCount = packetCountForWireBytes(
                scaledBytes,
                maxPayloadSize: maxPayloadSize
            )
        }
        if let lastRaisedFrameWireBytes {
            self.lastRaisedFrameWireBytes = Int(
                (Double(lastRaisedFrameWireBytes) * frameRateScale).rounded(.up)
            )
        }
    }

    mutating func retuneForBitrateChange(
        currentBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        startupCeilingBps: Int?,
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        allowsBudgetRaise: Bool
    ) {
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        guard let targetFrameWireBytes else { return }
        let nominalTarget = clampFrameWireBytes(
            wireBytes(forBitrate: input.currentBitrate, currentFrameRate: currentFrameRate),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let existingTarget = clampFrameWireBytes(
            targetFrameWireBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let retunedTarget = allowsBudgetRaise ? nominalTarget : min(existingTarget, nominalTarget)
        guard retunedTarget != existingTarget else { return }
        setTargetFrameWireBytes(
            retunedTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    /// Idle screens ramp the budget freely (frames are tiny while the source is
    /// still), so the target can exceed what the path was last proven to clear at
    /// realtime deadlines. Called on the still→motion transition before the first
    /// motion frame is encoded: clamps the budget to learned capacity at the
    /// realtime clear target so the burst starts deliverable instead of piling up.
    mutating func prepareForMotionOnset(
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
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard targetFrameWireBytes != nil else { return nil }
        let input = budgetInput(
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: requestedTargetBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile
        )
        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let currentTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let motionClearMs = mediaPathProfile.usesAwdlRadioPolicy
            ? policy.targetClearMs
            : Self.inputMotionQualityTargetClearMs
        let safeBytes = safeFrameWireBytes(
            targetClearMs: motionClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        guard safeBytes < currentTarget else { return nil }
        setTargetFrameWireBytes(
            safeBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let appliedTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let appliedScale = Float(min(1.0, Double(appliedTarget) / Double(max(1, currentTarget))))
        let quality = max(
            qualityFloor,
            min(steadyQualityCeiling, currentQuality * max(0.5, appliedScale))
        )
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.20)
        return makeDecision(
            state: .observing,
            reason: .motionOnset,
            quality: quality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    private func frameBudgetReductionAllowed(
        mediaPathProfile: MirageMediaPathProfile,
        awdlQualityReductionAllowed: Bool
    ) -> Bool {
        !mediaPathProfile.usesAwdlRadioPolicy || awdlQualityReductionAllowed
    }

    /// Datagram-registration churn right after stream start produces transient
    /// deadline drops that say nothing about path capacity. During the startup
    /// protection window those detectors get a single bounded cut.
    private mutating func consumeStartupGraceCutAllowance(startupProtectionActive: Bool) -> Bool {
        guard startupProtectionActive else {
            startupGraceCutApplied = false
            return true
        }
        guard !startupGraceCutApplied else { return false }
        startupGraceCutApplied = true
        return true
    }

    private mutating func cutBudget(
        scale: Double,
        state: PressureState,
        reason: Reason,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let currentTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let boundedScale = max(0.10, min(0.98, scale))
        var desiredTarget = Int((Double(currentTarget) * boundedScale).rounded(.down))
        // One underlying event usually fires several detectors within the same beat
        // (a freeze episode reports freshness, sender deadline, and recovery together).
        // Within the coalescing window a repeat of the same reason is a no-op, and a
        // different reason deepens the cut only to its own scale of the pre-event
        // target instead of compounding multiplicatively.
        if lastPanicCutTime > 0, now - lastPanicCutTime <= Self.cutCoalescingWindowSeconds {
            if reason == lastPanicCutReason {
                desiredTarget = currentTarget
            } else {
                let preEventTarget = lastPanicCutPreTargetWireBytes ?? currentTarget
                let preEventFloor = Int((Double(preEventTarget) * boundedScale).rounded(.down))
                desiredTarget = min(currentTarget, max(desiredTarget, preEventFloor))
            }
        } else {
            lastPanicCutPreTargetWireBytes = currentTarget
        }
        if desiredTarget < currentTarget {
            setTargetFrameWireBytes(
                desiredTarget,
                input: input,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize
            )
            lastPanicCutTime = now
            lastPanicCutReason = reason
        }
        let appliedTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        let appliedScale = Float(min(1.0, Double(appliedTarget) / Double(max(1, currentTarget))))
        let decisionQuality = max(
            qualityFloor,
            min(steadyQualityCeiling, currentQuality * appliedScale)
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
            mediaPathProfile: mediaPathProfile,
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
        mediaPathProfile: MirageMediaPathProfile,
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
        let runtimeQualityCeiling = runtimeQualityCeiling(
            state: state,
            reason: reason,
            boundedQuality: boundedQuality,
            steadyQualityCeiling: steadyQualityCeiling,
            input: input,
            mediaPathProfile: mediaPathProfile
        )
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

    private mutating func lowMotionRampViabilityDecision(
        snapshot: HostPFrameViabilitySnapshot?,
        deliveryMode: HostFrameDeliveryMode,
        receiverHealthy: Bool,
        senderHealthy: Bool,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor _: Float,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard deliveryMode == .lowMotionRamp,
              receiverHealthy,
              senderHealthy,
              let snapshot,
              snapshot.requiredBitrateBps > input.currentBitrate,
              snapshot.requiredBitrateBps <= input.maximumCeiling else {
            return nil
        }
        let requiredFrameBytes = wireBytes(
            forBitrate: snapshot.requiredBitrateBps,
            currentFrameRate: currentFrameRate
        )
        let currentTarget = currentTargetFrameWireBytes(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        guard requiredFrameBytes > currentTarget else { return nil }
        setTargetFrameWireBytes(
            requiredFrameBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        lastRaisedFrameWireBytes = requiredFrameBytes
        return makeDecision(
            state: .observing,
            reason: .healthy,
            quality: currentQuality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    private func runtimeQualityCeiling(
        state: PressureState,
        reason: Reason,
        boundedQuality: Float,
        steadyQualityCeiling: Float,
        input: BudgetInput,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Float {
        guard state != .observing else { return steadyQualityCeiling }
        let pressureCeiling = max(0.02, min(steadyQualityCeiling, boundedQuality * 1.08))
        guard mediaPathProfile == .vpnOrOverlay,
              input.usesOptimizedVPNProfile else {
            return pressureCeiling
        }
        let floor = optimizedVPNRuntimeQualityCeilingFloor(state: state, reason: reason)
        return min(steadyQualityCeiling, max(pressureCeiling, floor))
    }

    private func optimizedVPNRuntimeQualityCeilingFloor(
        state: PressureState,
        reason: Reason
    ) -> Float {
        switch (state, reason) {
        case (.severe, .receiverLoss),
             (.severe, .clientRecovery),
             (.severe, .receiverFreshness),
             (.recovery, _):
            Self.optimizedVPNSevereRuntimeQualityCeilingFloor
        default:
            Self.optimizedVPNTransientRuntimeQualityCeilingFloor
        }
    }

    private mutating func initializeIfNeeded(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
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
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
            )
        )
        setTargetFrameWireBytes(
            initialBytes,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
        learnedBytesPerMs = defaultBytesPerMs(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
    }

    private func startupProbeFrameWireBytes(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> Int {
        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let startupBytes = policy.startupFrameWireBytesAt60FPS
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
        minimumBitrateFloorBps: Int,
        currentFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) -> BudgetInput {
        let requested = max(1, requestedTargetBitrateBps ?? currentBitrateBps ?? startupCeilingBps ?? minimumBitrateFloorBps)
        let current = max(1, currentBitrateBps ?? requested)
        let floor = max(1, minimumBitrateFloorBps)
        let ceiling: Int
        let currentBitrate: Int
        let requestedBitrate: Int
        if mediaPathProfile.usesAwdlRadioPolicy, let startupCeilingBps {
            ceiling = max(floor, startupCeilingBps)
            currentBitrate = min(max(floor, current), ceiling)
            requestedBitrate = min(max(floor, requested), ceiling)
        } else {
            ceiling = max(current, requested, startupCeilingBps ?? requested, floor)
            currentBitrate = max(floor, current)
            requestedBitrate = max(floor, requested)
        }
        return BudgetInput(
            currentBitrate: currentBitrate,
            requestedBitrate: requestedBitrate,
            maximumCeiling: ceiling,
            floor: floor,
            usesOptimizedVPNProfile: Self.usesOptimizedVPNProfile(
                mediaPathProfile: mediaPathProfile,
                currentFrameRate: currentFrameRate,
                requestedBitrateBps: requested,
                startupCeilingBps: startupCeilingBps
            )
        )
    }

    private static func usesOptimizedVPNProfile(
        mediaPathProfile: MirageMediaPathProfile,
        currentFrameRate: Int,
        requestedBitrateBps: Int,
        startupCeilingBps: Int?
    ) -> Bool {
        guard mediaPathProfile == .vpnOrOverlay,
              currentFrameRate == 30,
              optimizedVPNProfileStartupBitratesBps.contains(requestedBitrateBps),
              let startupCeilingBps,
              startupCeilingBps >= requestedBitrateBps else {
            return false
        }
        return true
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
        let maximum = maximumCeilingFrameWireBytes(
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
        case .lowMotionRamp:
            if elapsed >= Self.passiveFailureProbeWindowSeconds * 0.5 {
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

    private func maximumCeilingFrameWireBytes(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Int {
        clampFrameWireBytes(
            wireBytes(forBitrate: input.maximumCeiling, currentFrameRate: currentFrameRate),
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func recentPressureRaiseCooldown(for motionClass: MotionClass, now: CFAbsoluteTime) -> CFAbsoluteTime {
        guard lastReceiverPressureTime > 0 else { return 0 }
        let elapsed = max(0, now - lastReceiverPressureTime)
        switch motionClass {
        case .still:
            return 0
        case .lowMotionRamp:
            guard elapsed < Self.passiveFailureProbeWindowSeconds * 0.5 else { return 0 }
            return Self.recentPassivePressureRaiseCooldownSeconds
        case .passive:
            guard elapsed < Self.passiveFailureProbeWindowSeconds else { return 0 }
            return Self.recentPassivePressureRaiseCooldownSeconds
        case .input:
            guard elapsed < Self.failureProbeWindowSeconds else { return 0 }
            return Self.recentInputPressureRaiseCooldownSeconds
        }
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
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> Double {
        let learned = learnedBytesPerMs ?? defaultBytesPerMs(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        return Double(max(1, wireBytes)) / max(1, learned)
    }

    private func defaultBytesPerMs(
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> Double {
        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        guard mediaPathProfile.usesAwdlRadioPolicy else {
            return Double(max(1, input.currentBitrate)) / 8.0 / 1_000.0
        }
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
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> Int {
        let policy = ModePolicy.policy(
            for: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        return safeFrameWireBytes(
            targetClearMs: policy.targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
    }

    private func safeFrameWireBytes(
        targetClearMs: Double,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile = .unknown,
        receiverPlayoutDelayTargetMs: Double? = nil
    ) -> Int {
        let learned = learnedBytesPerMs ?? defaultBytesPerMs(
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        return safeFrameWireBytes(
            sampleBytesPerMs: learned,
            targetClearMs: targetClearMs,
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

    private mutating func predictivePFrameOversizeDecision(
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        qualityStillEnough: Bool,
        sourceStill: Bool,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        currentQuality: Float,
        qualityFloor: Float,
        steadyQualityCeiling: Float,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard let lastWireBytes = lastAdmittedPFrameWireBytes,
              let lastPacketCount = lastAdmittedPFramePacketCount else {
            return nil
        }
        let predictedWireBytes = max(wireBytes, lastWireBytes)
        let predictedPacketCount = max(packetCount, lastPacketCount)
        let wirePressureRatio = Double(max(0, predictedWireBytes)) / Double(max(1, targetBytes))
        let packetPressureRatio = Double(max(0, predictedPacketCount)) / Double(max(1, packetTarget))
        let exceedsTarget = wirePressureRatio >= Self.predictivePFrameOversizeTargetRatio ||
            packetPressureRatio >= Self.predictivePFrameOversizePacketRatio
        let exceedsCleanSpike = predictivePFrameExceedsCleanSpike(
            wireBytes: predictedWireBytes,
            packetCount: predictedPacketCount
        )
        let actionableCleanSpike = exceedsCleanSpike &&
            (predictedWireBytes >= Self.motionGrowthPFrameMinimumWireBytes ||
                wirePressureRatio >= 0.85 ||
                packetPressureRatio >= 0.85)
        let motionGrowthPressureRatio = predictivePFrameMotionGrowthPressureRatio(
            wireBytes: wireBytes,
            packetCount: packetCount,
            lastWireBytes: lastWireBytes,
            lastPacketCount: lastPacketCount,
            sourceStill: sourceStill
        )
        let stillEnoughMotionSpike = !sourceStill && (actionableCleanSpike || motionGrowthPressureRatio != nil)
        guard !qualityStillEnough || stillEnoughMotionSpike else { return nil }
        guard exceedsTarget || actionableCleanSpike || motionGrowthPressureRatio != nil else { return nil }

        let pressureRatio = max(wirePressureRatio, packetPressureRatio, motionGrowthPressureRatio ?? 0)
        let minimumCutScale = motionGrowthPressureRatio == nil
            ? Self.predictivePFrameMinimumCutScale
            : Self.motionGrowthPFrameMinimumCutScale
        let maximumCutScale = motionGrowthPressureRatio == nil
            ? Self.predictivePFrameMaximumCutScale
            : Self.motionGrowthPFrameMaximumCutScale
        let cutScale = max(
            minimumCutScale,
            min(maximumCutScale, Self.safeDeliveryUtilization / max(1.0, pressureRatio))
        )
        let nextBudget = Int((Double(targetBytes) * cutScale).rounded(.down))
        recordPressureCeiling(
            failedTarget: max(targetBytes, predictedWireBytes),
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
        qualityRaiseSuppressedUntil = max(qualityRaiseSuppressedUntil, now + 0.10)
        return makeDecision(
            state: .pressured,
            reason: .encodedFrame,
            quality: quality,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            steadyQualityCeiling: steadyQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    private func predictivePFrameExceedsCleanSpike(
        wireBytes: Int,
        packetCount: Int
    ) -> Bool {
        guard let baselineWireBytes = recentCleanPFrameBaselineWireBytes,
              let baselinePacketCount = recentCleanPFrameBaselinePacketCount else {
            return false
        }
        let allowedSpikeRatio = Self.allowedPFrameSpikeRatio(baselineWireBytes: baselineWireBytes)
        let allowedWireBytes = Int((Double(max(1, baselineWireBytes)) * allowedSpikeRatio).rounded(.up))
        let allowedPacketCount = Self.allowedPFrameSpikePacketCount(
            baselinePacketCount: baselinePacketCount,
            allowedSpikeRatio: allowedSpikeRatio
        )
        return wireBytes > allowedWireBytes || packetCount > allowedPacketCount
    }

    private func predictivePFrameMotionGrowthPressureRatio(
        wireBytes: Int,
        packetCount: Int,
        lastWireBytes: Int,
        lastPacketCount: Int,
        sourceStill: Bool
    ) -> Double? {
        pFrameMotionGrowthPressureRatio(
            wireBytes: wireBytes,
            packetCount: packetCount,
            baselineWireBytes: lastWireBytes,
            baselinePacketCount: lastPacketCount,
            sourceStill: sourceStill,
            minimumWireBytes: Self.motionGrowthPFrameMinimumWireBytes,
            minimumGrowthBytes: 0,
            wireRatio: Self.motionGrowthPFrameWireRatio,
            packetRatio: Self.motionGrowthPFramePacketRatio
        )
    }

    private func receiverCadenceMotionGrowthPressureRatio(
        wireBytes: Int,
        packetCount: Int,
        sourceStill: Bool
    ) -> Double? {
        var result: Double?
        if let lastWireBytes = lastAdmittedPFrameWireBytes,
           let lastPacketCount = lastAdmittedPFramePacketCount {
            result = pFrameMotionGrowthPressureRatio(
                wireBytes: wireBytes,
                packetCount: packetCount,
                baselineWireBytes: lastWireBytes,
                baselinePacketCount: lastPacketCount,
                sourceStill: sourceStill,
                minimumWireBytes: Self.receiverCadenceMotionGrowthMinimumWireBytes,
                minimumGrowthBytes: Self.receiverCadenceMotionGrowthMinimumDeltaBytes,
                wireRatio: Self.receiverCadenceMotionGrowthWireRatio,
                packetRatio: Self.receiverCadenceMotionGrowthPacketRatio
            )
        }
        if let baselineWireBytes = recentCleanPFrameBaselineWireBytes,
           let baselinePacketCount = recentCleanPFrameBaselinePacketCount,
           let baselineResult = pFrameMotionGrowthPressureRatio(
               wireBytes: wireBytes,
               packetCount: packetCount,
               baselineWireBytes: baselineWireBytes,
               baselinePacketCount: baselinePacketCount,
               sourceStill: sourceStill,
               minimumWireBytes: Self.receiverCadenceMotionGrowthMinimumWireBytes,
               minimumGrowthBytes: Self.receiverCadenceMotionGrowthMinimumDeltaBytes,
               wireRatio: Self.receiverCadenceMotionGrowthWireRatio,
               packetRatio: Self.receiverCadenceMotionGrowthPacketRatio
           ) {
            result = max(result ?? 0, baselineResult)
        }
        return result
    }

    private func pFrameMotionGrowthPressureRatio(
        wireBytes: Int,
        packetCount: Int,
        baselineWireBytes: Int,
        baselinePacketCount: Int,
        sourceStill: Bool,
        minimumWireBytes: Int,
        minimumGrowthBytes: Int,
        wireRatio: Double,
        packetRatio: Double
    ) -> Double? {
        guard !sourceStill else { return nil }
        guard wireBytes >= minimumWireBytes else { return nil }
        guard wireBytes - baselineWireBytes >= minimumGrowthBytes else { return nil }
        let wireGrowthRatio = Double(max(1, wireBytes)) / Double(max(1, baselineWireBytes))
        let packetGrowthRatio = Double(max(1, packetCount)) / Double(max(1, baselinePacketCount))
        guard wireGrowthRatio >= wireRatio || packetGrowthRatio >= packetRatio else { return nil }
        return max(wireGrowthRatio, packetGrowthRatio)
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
        targetClearMs: Double,
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
            targetClearMs: targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode
        )
        let headroomBytes = max(targetBytes, safeBytes)
        guard wireBytes > Int((Double(headroomBytes) * Self.catastrophicPFrameHeadroomRatio).rounded(.up)),
              predictedDeliveryMs > targetClearMs * Self.catastrophicPFramePredictedClearRatio else {
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

    private func motionBurstPFrameRepairTargetWireBytes(
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        predictedDeliveryMs: Double,
        targetClearMs: Double,
        inputActive: Bool,
        sourceStill: Bool,
        qualityStillEnough: Bool,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile,
        receiverPlayoutDelayTargetMs: Double?
    ) -> Int? {
        guard usesMotionBurstPFrameRepair(mediaPathProfile: mediaPathProfile),
              !sourceStill,
              !qualityStillEnough,
              predictedDeliveryMs > targetClearMs * 1.20 else {
            return nil
        }
        let minimumWireBytes = inputActive
            ? Self.inputMotionBurstDropMinimumWireBytes
            : Self.passiveMotionBurstDropMinimumWireBytes
        let pressureRatio = inputActive
            ? Self.inputMotionBurstDropRatio
            : Self.passiveMotionBurstDropRatio
        guard wireBytes >= minimumWireBytes else { return nil }
        let wireRatio = Double(max(0, wireBytes)) / Double(max(1, targetBytes))
        let packetRatio = Double(max(0, packetCount)) / Double(max(1, packetTarget))
        guard wireRatio >= pressureRatio || packetRatio >= pressureRatio else { return nil }

        let cutScale = oversizeCutScale(targetClearMs: targetClearMs, predictedDeliveryMs: predictedDeliveryMs)
        let safeBytes = safeFrameWireBytes(
            targetClearMs: targetClearMs,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
        let repairTarget = min(
            targetBytes,
            Int((Double(targetBytes) * cutScale).rounded(.down)),
            safeBytes
        )
        return clampFrameWireBytes(
            repairTarget,
            input: input,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize
        )
    }

    private func usesMotionBurstPFrameRepair(mediaPathProfile: MirageMediaPathProfile) -> Bool {
        switch mediaPathProfile {
        case .localWiFi,
             .wired,
             .proximityWiredLike:
            return true
        case .awdlRadio,
             .vpnOrOverlay,
             .other,
             .unknown:
            return false
        }
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
        senderHealthy: Bool,
        updatesCleanBaseline: Bool = true
    ) {
        lastAdmittedPFrameWireBytes = wireBytes
        lastAdmittedPFramePacketCount = packetCount
        lastAdmittedPFrameQuality = quality
        guard updatesCleanBaseline else { return }
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
        targetClearMs: Double,
        wireBytes: Int,
        packetCount: Int,
        targetBytes: Int,
        packetTarget: Int,
        input: BudgetInput,
        currentFrameRate: Int,
        maxPayloadSize: Int
    ) -> Bool {
        guard pressureDeliveryMs <= targetClearMs * Self.nearFloorPressureTargetRatio else {
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

    private func qualityTargetClearMs(
        policy: ModePolicy,
        inputActive: Bool,
        sourceStill: Bool,
        stillEnough: Bool,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Double {
        guard !mediaPathProfile.usesAwdlRadioPolicy else { return policy.targetClearMs }
        if stillEnough || sourceStill {
            return max(policy.targetClearMs, Self.lowMotionQualityTargetClearMs)
        }
        return inputActive ? Self.inputMotionQualityTargetClearMs : Self.passiveMotionQualityTargetClearMs
    }

    private func timingTargetClearMs(
        _ baseTargetClearMs: Double,
        currentQuality: Float,
        input: BudgetInput,
        mediaPathProfile: MirageMediaPathProfile,
        receiverHealthy: Bool,
        senderHealthy: Bool
    ) -> Double {
        baseTargetClearMs * vpnReadableQualityTimingScale(
            currentQuality: currentQuality,
            input: input,
            mediaPathProfile: mediaPathProfile,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy
        )
    }

    private func sendDeadline(now: CFAbsoluteTime, currentFrameRate: Int) -> CFAbsoluteTime {
        now + frameInterval(for: currentFrameRate)
    }

    private func lowMotionRampSendDeadline(
        now: CFAbsoluteTime,
        deliveryMode: HostFrameDeliveryMode,
        mediaPathProfile: MirageMediaPathProfile
    ) -> CFAbsoluteTime {
        guard deliveryMode == .lowMotionRamp else { return now }
        return now + HostPFrameViabilityController.targetClearMilliseconds(
            deliveryMode: deliveryMode,
            mediaPathProfile: mediaPathProfile
        ) / 1_000.0
    }

    private func sendDeadline(
        now: CFAbsoluteTime,
        currentFrameRate: Int,
        currentQuality: Float,
        input: BudgetInput,
        mediaPathProfile: MirageMediaPathProfile,
        receiverHealthy: Bool,
        senderHealthy: Bool
    ) -> CFAbsoluteTime {
        let frameInterval = frameInterval(for: currentFrameRate)
        let timingPolicy = vpnReadableQualityTimingPolicy(
            mediaPathProfile: mediaPathProfile,
            usesOptimizedVPNProfile: input.usesOptimizedVPNProfile
        )
        let timingScale = vpnReadableQualityTimingScale(
            currentQuality: currentQuality,
            input: input,
            mediaPathProfile: mediaPathProfile,
            receiverHealthy: receiverHealthy,
            senderHealthy: senderHealthy
        )
        let timingProgress = max(
            0.0,
            min(1.0, (timingScale - 1.0) / max(0.001, timingPolicy.maximumTimingScale - 1.0))
        )
        let deadlineFrameScale = 1.0 +
            (Self.vpnReadableQualityMaximumDeadlineFrames - 1.0) * timingProgress
        let deadlineSeconds = min(
            frameInterval * deadlineFrameScale,
            timingPolicy.maximumSendDeadlineMs / 1_000.0
        )
        return now + max(frameInterval, deadlineSeconds)
    }

    private func frameInterval(for currentFrameRate: Int) -> CFAbsoluteTime {
        1.0 / Double(max(1, currentFrameRate))
    }

    private func vpnReadableQualityTimingScale(
        currentQuality: Float,
        input: BudgetInput,
        mediaPathProfile: MirageMediaPathProfile,
        receiverHealthy: Bool,
        senderHealthy: Bool
    ) -> Double {
        let timingPolicy = vpnReadableQualityTimingPolicy(
            mediaPathProfile: mediaPathProfile,
            usesOptimizedVPNProfile: input.usesOptimizedVPNProfile
        )
        guard mediaPathProfile == .vpnOrOverlay,
              receiverHealthy,
              senderHealthy,
              currentQuality < timingPolicy.target else {
            return 1.0
        }
        let denominator = max(
            0.001,
            Double(timingPolicy.target - timingPolicy.lowerBound)
        )
        let progress = max(
            0.0,
            min(
                1.0,
                Double(timingPolicy.target - max(currentQuality, timingPolicy.lowerBound)) /
                    denominator
            )
        )
        return 1.0 + (timingPolicy.maximumTimingScale - 1.0) * progress
    }

    private func vpnReadableQualityTimingPolicy(
        mediaPathProfile: MirageMediaPathProfile,
        usesOptimizedVPNProfile: Bool
    ) -> VPNReadableQualityTimingPolicy {
        guard mediaPathProfile == .vpnOrOverlay,
              usesOptimizedVPNProfile else {
            return VPNReadableQualityTimingPolicy(
                target: Self.vpnReadableQualityTarget,
                lowerBound: Self.vpnReadableQualityLowerBound,
                maximumTimingScale: Self.vpnReadableQualityMaximumTimingScale,
                maximumSendDeadlineMs: Self.vpnReadableQualityMaximumSendDeadlineMs
            )
        }
        return VPNReadableQualityTimingPolicy(
            target: Self.optimizedVPNReadableQualityTarget,
            lowerBound: Self.optimizedVPNReadableQualityLowerBound,
            maximumTimingScale: Self.optimizedVPNReadableQualityMaximumTimingScale,
            maximumSendDeadlineMs: Self.optimizedVPNReadableQualityMaximumSendDeadlineMs
        )
    }

    private func treatsFrameAsStillEnoughForQuality(
        inputActive: Bool,
        sourceStill: Bool,
        wireBytes: Int,
        packetCount _: Int
    ) -> Bool {
        if sourceStill { return true }
        guard !inputActive else { return false }
        if wireBytes <= Self.lowMotionStillMaximumWireBytes { return true }
        guard let baseline = recentCleanPFrameBaselineWireBytes else { return false }
        let relativeLimit = max(
            baseline + Self.lowMotionStillBaselineSlackBytes,
            Int((Double(baseline) * Self.lowMotionStillBaselineRatio).rounded(.up))
        )
        return wireBytes <= min(relativeLimit, Self.lowMotionStillBaselineMaximumWireBytes)
    }

    private func motionClass(
        inputActive: Bool,
        sourceStill: Bool,
        deliveryMode: HostFrameDeliveryMode
    ) -> MotionClass {
        if inputActive {
            return .input
        }
        if sourceStill {
            return .still
        }
        if deliveryMode == .lowMotionRamp {
            return .lowMotionRamp
        }
        return .passive
    }

    private func isFrameNumber(_ frameNumber: UInt64, newerThan current: UInt64) -> Bool {
        let difference = frameNumber &- current
        return difference != 0 && difference < 0x8000_0000_0000_0000
    }
}

#endif
