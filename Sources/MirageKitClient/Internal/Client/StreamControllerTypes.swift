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
    /// Maximum keyframe retries before escalating to a single hard reset.
    static let activeRecoveryMaxKeyframeAttempts = 3
    /// Grace period to let promotion continue with forward P-frames before forcing recovery.
    static let tierPromotionProbeDelay: Duration = .milliseconds(250)
    /// Minimum spacing between soft recoveries to avoid keyframe recovery storms.
    static let softRecoveryMinimumInterval: CFAbsoluteTime = 1.0
    /// Minimum spacing between hard recoveries to avoid repeated full pipeline resets.
    static let hardRecoveryMinimumInterval: CFAbsoluteTime = 2.5
    static let streamingAnomalyLogCooldown: CFAbsoluteTime = 5.0
    static let renderCadenceMissLogCooldown: CFAbsoluteTime = 5.0
    static let renderCadenceMissSampleThreshold = 3
    static let metricsDispatchInterval: Duration = .milliseconds(500)

    enum RecoveryReason: Equatable {
        case decodeErrorThreshold
        case frameLoss
        case freezeTimeout
        case keyframeRecoveryLoop
        case manualRecovery
        case memoryBudget
        case startupKeyframeTimeout

        var logLabel: String {
            switch self {
            case .decodeErrorThreshold:
                "decode-error-threshold"
            case .frameLoss:
                "frame-loss"
            case .freezeTimeout:
                "freeze-timeout"
            case .keyframeRecoveryLoop:
                "keyframe-recovery-loop"
            case .manualRecovery:
                "manual-recovery"
            case .memoryBudget:
                "memory-budget"
            case .startupKeyframeTimeout:
                "startup-keyframe-timeout"
            }
        }
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
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    struct ClientFrameMetrics {
        let decodedFPS: Double
        let receivedFPS: Double
        let receivedWorstGapMs: Double
        let receivedFrameIntervalP95Ms: Double
        let receivedFrameIntervalP99Ms: Double
        let droppedFrames: UInt64
        let displayTickFPS: Double
        let submitAttemptFPS: Double
        let layerAcceptedFPS: Double
        let presentedFPS: Double
        let submittedFPS: Double
        let uniqueSubmittedFPS: Double
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let overwrittenPendingFrames: UInt64
        let smoothestQueueDrops: UInt64
        let lateFrameDrops: UInt64
        let displayLayerNotReadyCount: UInt64
        let repeatedFrameCount: UInt64
        let missedVSyncCount: UInt64
        let displayTickIntervalP95Ms: Double
        let displayTickIntervalP99Ms: Double
        let playoutDelayFrames: Int
        let presentationStallCount: UInt64
        let worstPresentationGapMs: Double
        let frameIntervalP95Ms: Double
        let frameIntervalP99Ms: Double
        let decodeHealthy: Bool
        let activeJitterHoldMs: Int
        let reassemblerPendingFrameCount: Int
        let reassemblerPendingKeyframeCount: Int
        let reassemblerPendingBytes: Int
        let frameBufferPoolRetainedBytes: Int
        let reassemblerBudgetEvictions: UInt64
        let reassemblerIncompleteFrameTimeouts: UInt64
        let reassemblerMissingFragmentTimeouts: UInt64
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

    nonisolated static func bootstrapFirstFrameRecoveryAction(
        hasPackets: Bool,
        awaitingKeyframe: Bool,
        latestSequence: UInt64,
        baselineSequence: UInt64
    ) -> BootstrapFirstFrameRecoveryAction {
        guard hasPackets else { return .hardRecovery }
        guard latestSequence > baselineSequence || awaitingKeyframe else { return .hardRecovery }
        return awaitingKeyframe ? .requestKeyframe : .hardRecovery
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
