//
//  StreamControllerTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Stream controller decisions, metrics, and frame carriers.
//

import CoreGraphics
import CoreMedia
import Foundation
import MirageKit

extension StreamController {
    /// Maximum recovery keyframe requests over the sliding pressure window.
    static let recoveryKeyframeDispatchLimit = 3
    /// Sliding window for recovery keyframe request limiting.
    static let recoveryKeyframeDispatchWindow: CFAbsoluteTime = 10.0
    /// Grace period to let promotion continue with forward P-frames before forcing recovery.
    static let tierPromotionProbeDelay: Duration = .milliseconds(250)
    /// Minimum spacing between soft recoveries to avoid keyframe recovery storms.
    static let softRecoveryMinimumInterval: CFAbsoluteTime = 1.0
    /// Minimum spacing between hard recoveries to avoid repeated full pipeline resets.
    static let hardRecoveryMinimumInterval: CFAbsoluteTime = 2.5
    static let localDuplicateKeyframeRequestGrace: CFAbsoluteTime = 2.5
    static let remoteDuplicateKeyframeRequestGrace: CFAbsoluteTime = 8.0
    static let localAwaitingKeyframeNoProgressRetryGrace: CFAbsoluteTime = 1.0
    static let remoteAwaitingKeyframeNoProgressRetryGrace: CFAbsoluteTime = 2.0
    static let localHardRecoveryNoProgressFloor: CFAbsoluteTime = 8.0
    static let remoteHardRecoveryNoProgressFloor: CFAbsoluteTime = 20.0
    static let localPacketProgressFreshThreshold: CFAbsoluteTime = 2.0
    static let remotePacketProgressFreshThreshold: CFAbsoluteTime = 6.0
    static let streamingAnomalyLogCooldown: CFAbsoluteTime = 5.0
    static let renderCadenceMissLogCooldown: CFAbsoluteTime = 5.0
    static let renderCadenceMissSampleThreshold = 3
    static let adaptivePresentationSmoothingActivationSamples = 2
    static let adaptivePresentationSmoothingReleaseSamples = 6
    static let adaptivePresentationSmoothingCooldown: CFAbsoluteTime = 2.0
    static let metricsDispatchInterval: Duration = .milliseconds(100)

    enum RecoveryReason: Equatable {
        case decodeErrorThreshold
        case decodeQueueDependencyBreak
        case frameLoss
        case freezeTimeout
        case manualRecovery
        case memoryBudget
        case startupKeyframeTimeout

        var logLabel: String {
            switch self {
            case .decodeErrorThreshold:
                "decode-error-threshold"
            case .decodeQueueDependencyBreak:
                "decode-queue-dependency-break"
            case .frameLoss:
                "frame-loss"
            case .freezeTimeout:
                "freeze-timeout"
            case .manualRecovery:
                "manual-recovery"
            case .memoryBudget:
                "memory-budget"
            case .startupKeyframeTimeout:
                "startup-keyframe-timeout"
            }
        }

        var recoveryCause: MirageStreamClientRecoveryCause {
            switch self {
            case .decodeErrorThreshold:
                .decodeError
            case .decodeQueueDependencyBreak:
                .frameLoss
            case .frameLoss:
                .frameLoss
            case .freezeTimeout:
                .freezeTimeout
            case .manualRecovery:
                .manual
            case .memoryBudget:
                .memoryBudget
            case .startupKeyframeTimeout:
                .startupTimeout
            }
        }

        var allowsExplicitKeyframeRequest: Bool {
            switch self {
            case .decodeErrorThreshold,
                 .decodeQueueDependencyBreak,
                 .freezeTimeout,
                 .manualRecovery,
                 .startupKeyframeTimeout:
                true
            case .frameLoss,
                 .memoryBudget:
                false
            }
        }

        var bypassesBootstrapRetryGates: Bool {
            switch self {
            case .startupKeyframeTimeout:
                true
            case .decodeErrorThreshold,
                 .decodeQueueDependencyBreak,
                 .frameLoss,
                 .freezeTimeout,
                 .manualRecovery,
                 .memoryBudget:
                false
            }
        }
    }

    enum StreamRecoveryDecision: String, Equatable {
        case requestKeyframe = "request-keyframe"
        case deferPacketsFlowing = "defer-packets-flowing"
        case deferKeyframeProgress = "defer-keyframe-progress"
        case deferRetryGrace = "defer-retry-grace"
        case presenterRecovery = "presenter-recovery"
        case hardRecovery = "hard-recovery"
    }

    enum FreezeStallKind: String, Equatable {
        case keyframeStarved = "keyframe-starved"
        case packetStarved = "packet-starved"
        case monitoringOnly = "monitoring-only"
    }

    enum FreezeRecoveryDecision: Equatable {
        case soft(FreezeStallKind)
        case hard(FreezeStallKind)
        case monitor(FreezeStallKind)
    }

    enum FreezeRecoveryEpisodeState: String, Equatable {
        case presenterProbe = "presenter-probe"
    }

    struct FreezeRecoveryEpisode: Equatable {
        let id: UInt64
        var state: FreezeRecoveryEpisodeState
        let startedAt: CFAbsoluteTime
        let baselineSubmittedCursor: MirageRenderCursor
        var lastActionTime: CFAbsoluteTime
        var presenterProbeAttempted: Bool
    }

    enum FirstPresentedFrameAwaitMode: Equatable {
        case startup
        case recovery
    }

    enum BootstrapFirstFrameRecoveryAction: Equatable {
        case requestKeyframe
        case hardRecovery
    }

    struct TerminalStartupFailure: Equatable {
        static let errorMessage = MirageKit.firstFramePresentationFailureTerminalMessage

        let reason: RecoveryReason
        let hardRecoveryAttempts: Int
        let waitReason: String?
    }

    enum ResizeState: Equatable {
        case idle
    }

    struct FrameData {
        let data: Data
        let presentationTime: CMTime
        let isKeyframe: Bool
        let frameNumber: UInt32?
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    struct ClientFrameMetrics {
        let decodedFPS: Double
        let receivedFPS: Double
        let receivedWorstGapMs: Double
        let receivedFrameIntervalP95Ms: Double
        let receivedFrameIntervalP99Ms: Double
        let receiverIngressJitterP95Ms: Double
        let receiverIngressJitterP99Ms: Double
        let droppedFrames: UInt64
        let decodeBacklogFrames: Int
        let decodeSubmissionLimit: Int
        let inFlightDecodeSubmissions: Int
        let displayTickFPS: Double
        let submitAttemptFPS: Double
        let layerAcceptedFPS: Double
        let visibleFrameFPS: Double
        let submittedFPS: Double
        let uniqueSubmittedFPS: Double
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let smoothestDisplayDebtMs: Double
        let smoothestDisplayDebtCapMs: Double
        let smoothestTargetDelayMs: Double
        let overwrittenPendingFrames: UInt64
        let smoothestQueueDrops: UInt64
        let smoothestDisplayDebtDrops: UInt64
        let smoothestFifoResetCount: UInt64
        let smoothestDepthDrops: UInt64
        let smoothestAgeDrops: UInt64
        let smoothestDropsUnder100ms: UInt64
        let smoothestDroppedFrameAgeMaxMs: Double
        let lateFrameDrops: UInt64
        let displayLayerNotReadyCount: UInt64
        let repeatedFrameCount: UInt64
        let displayTickNoFrameCount: UInt64
        let pendingFrameNotReadyDisplayTickCount: UInt64
        let missedVSyncCount: UInt64
        let displayTickIntervalP95Ms: Double
        let displayTickIntervalP99Ms: Double
        let playoutDelayFrames: Int
        let presentationStallCount: UInt64
        let worstPresentationGapMs: Double
        let frameIntervalP95Ms: Double
        let frameIntervalP99Ms: Double
        let decodeHealthy: Bool
        let reassemblerPendingFrameCount: Int
        let reassemblerPendingKeyframeCount: Int
        let reassemblerPendingBytes: Int
        let frameBufferPoolRetainedBytes: Int
        let reassemblerBudgetEvictions: UInt64
        let reassemblerIncompleteFrameTimeouts: UInt64
        let reassemblerIncompleteFrameNoProgressTimeouts: UInt64
        let reassemblerIncompleteFrameLifetimeTimeouts: UInt64
        let reassemblerMissingFragmentTimeouts: UInt64
        let reassemblerForwardGapTimeouts: UInt64
        let reassemblerFrameCompletionLatencyP50Ms: Double
        let reassemblerFrameCompletionLatencyP95Ms: Double
        let reassemblerFrameCompletionLatencyMaxMs: Double
        let reassemblerKeyframeCompletionLatencyP50Ms: Double
        let reassemblerKeyframeCompletionLatencyP95Ms: Double
        let reassemblerKeyframeCompletionLatencyMaxMs: Double
        let reassemblerPFrameCompletionLatencyP50Ms: Double
        let reassemblerPFrameCompletionLatencyP95Ms: Double
        let reassemblerPFrameCompletionLatencyMaxMs: Double
        let reassemblerLatePFrameCompletionCount: UInt64
        let reassemblerFECRecoveredFragmentCount: UInt64
        let decoderOutputPixelFormat: String?
        let usingHardwareDecoder: Bool?
    }

    nonisolated static func freezeRecoveryDecision(
        keyframeStarved: Bool,
        packetStarved: Bool,
        consecutiveFreezeRecoveries: Int
    ) -> FreezeRecoveryDecision {
        if keyframeStarved {
            if consecutiveFreezeRecoveries >= freezeRecoveryEscalationThreshold {
                return .hard(.keyframeStarved)
            }
            return .soft(.keyframeStarved)
        }

        if packetStarved {
            if consecutiveFreezeRecoveries >= freezeRecoveryEscalationThreshold {
                return .hard(.packetStarved)
            }
            return .soft(.packetStarved)
        }

        return .monitor(.monitoringOnly)
    }

    nonisolated static func firstPresentedFrameBootstrapRecoveryGrace(
        for mode: FirstPresentedFrameAwaitMode
    ) -> CFAbsoluteTime {
        switch mode {
        case .startup:
            startupFirstPresentedFrameBootstrapRecoveryGrace
        case .recovery:
            recoveryFirstPresentedFrameBootstrapRecoveryGrace
        }
    }

    nonisolated static func firstPresentedFrameHardRecoveryGrace(
        for mode: FirstPresentedFrameAwaitMode
    ) -> CFAbsoluteTime {
        switch mode {
        case .startup:
            startupFirstPresentedFrameHardRecoveryGrace
        case .recovery:
            recoveryFirstPresentedFrameHardRecoveryGrace
        }
    }

    nonisolated static func bootstrapFirstFrameRecoveryAction(
        hasAcceptedPackets: Bool,
        latestSequence: UInt64,
        baselineSequence: UInt64
    ) -> BootstrapFirstFrameRecoveryAction {
        guard hasAcceptedPackets else { return .hardRecovery }
        guard latestSequence <= baselineSequence else { return .hardRecovery }
        return .requestKeyframe
    }

    nonisolated static func shouldAttemptRendererRecoveryBeforeBootstrapReset(
        pendingFrameCount: Int,
        submittedSequence: UInt64,
        baselineSequence: UInt64,
        rendererRecoveryAttempts: Int
    )
    -> Bool {
        pendingFrameCount > 0 &&
            submittedSequence == 0 &&
            baselineSequence == 0 &&
            rendererRecoveryAttempts == 0
    }

    nonisolated static func shouldDispatchRecovery(
        lastDispatchTime: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        minimumInterval: CFAbsoluteTime
    )
    -> Bool {
        guard minimumInterval > 0 else { return true }
        guard let lastDispatchTime, lastDispatchTime > 0 else { return true }
        return now - lastDispatchTime >= minimumInterval
    }
}
