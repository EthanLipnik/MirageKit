//
//  StreamController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

struct FrameQueueTicket: Sendable, Equatable {
    let pipelineGeneration: UInt64
    let queueEpoch: UInt64
    let order: UInt64
}

private final class FrameEnqueueOrderAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrder: UInt64 = 0
    private var queueEpoch: UInt64 = 0

    func allocate(pipelineGeneration: UInt64) -> FrameQueueTicket {
        lock.lock()
        let ticket = FrameQueueTicket(
            pipelineGeneration: pipelineGeneration,
            queueEpoch: queueEpoch,
            order: nextOrder
        )
        nextOrder &+= 1
        lock.unlock()
        return ticket
    }

    func reset() {
        lock.lock()
        queueEpoch &+= 1
        nextOrder = 0
        lock.unlock()
    }

    func currentQueueEpoch() -> UInt64 {
        lock.lock()
        let epoch = queueEpoch
        lock.unlock()
        return epoch
    }
}

/// Controls the lifecycle and state of a single stream.
/// Owned by MirageClientService, not by views. This ensures:
/// - Decoder lifecycle is independent of SwiftUI lifecycle
/// - Resize state machine can be tested without SwiftUI
/// - Frame distribution is not blocked by MainActor
actor StreamController {
    // MARK: - Types

    enum RecoveryReason: Sendable, Equatable {
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

    enum FreezeStallKind: String, Sendable, Equatable {
        case keyframeStarved = "keyframe-starved"
        case packetStarved = "packet-starved"
        case monitoringOnly = "monitoring-only"
    }

    enum FreezeRecoveryDecision: Sendable, Equatable {
        case soft(FreezeStallKind)
        case hard(FreezeStallKind)
        case monitor(FreezeStallKind)
    }

    enum FirstPresentedFrameAwaitMode: Sendable, Equatable {
        case startup
        case recovery
    }

    enum BootstrapFirstFrameRecoveryAction: Sendable, Equatable {
        case requestKeyframe
        case hardRecovery
    }

    struct DecodeQueueAdmissionLimits: Sendable, Equatable {
        let recoveryThreshold: Int
        let hardLimit: Int
    }

    struct TerminalStartupFailure: Sendable, Equatable {
        let reason: RecoveryReason
        let hardRecoveryAttempts: Int
        let waitReason: String?

        var errorMessage: String {
            "Stream failed to present its first frame after bounded recovery."
        }
    }

    struct TerminalLiveRecoveryFailure: Sendable, Equatable {
        let reason: RecoveryReason
        let hardRecoveryAttempts: Int
        let waitReason: String?
        let decodedFPS: Double
        let receivedFPS: Double
        let layerEnqueueFPS: Double
        let uniqueLayerEnqueueFPS: Double
        let visibleFrameFPS: Double
        let visibleFrameCadenceKnown: Bool

        var errorMessage: String {
            "Stream failed to recover stable presentation after bounded live recovery."
        }
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

    /// State of the resize operation
    enum ResizeState: Equatable, Sendable {
        case idle
        case awaiting(expectedSize: CGSize)
        case confirmed(finalSize: CGSize)
    }

    /// Information needed to send a resize event
    struct ResizeEvent: Sendable {
        let aspectRatio: CGFloat
        let relativeScale: CGFloat
        let clientScreenSize: CGSize
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Frame data for ordered decode queue
    struct FrameData: Sendable {
        let data: Data
        let frameNumber: UInt32
        let remotePresentationTime: CMTime
        let presentationTime: CMTime
        let isKeyframe: Bool
        let contentRect: CGRect
        let renderGeneration: UInt64
        let hostEpoch: UInt16
        let dimensionToken: UInt16
        let timeline: FrameTimeline
        let queueTicket: FrameQueueTicket
        let releaseBuffer: @Sendable () -> Void

        func decodeContext(submittedAt time: CFAbsoluteTime) -> MirageVideoDecodeFrameContext {
            MirageVideoDecodeFrameContext(
                renderGeneration: renderGeneration,
                queueEpoch: queueTicket.queueEpoch,
                hostEpoch: hostEpoch,
                dimensionToken: dimensionToken,
                frameNumber: frameNumber,
                remotePresentationTime: remotePresentationTime,
                timeline: timeline.markingDecodeSubmitted(at: time)
            )
        }
    }

    struct ClientFrameMetrics: Sendable {
        let decodedFPS: Double
        let receivedFPS: Double
        let decodedWorstGapMs: Double
        let decodedFrameIntervalP95Ms: Double
        let decodedFrameIntervalP99Ms: Double
        let receivedWorstGapMs: Double
        let receivedFrameIntervalP95Ms: Double
        let receivedFrameIntervalP99Ms: Double
        let droppedFrames: UInt64
        let renderStoreEnqueueFPS: Double
        let displayLinkCallbackFPS: Double
        let displayTickWorkerFPS: Double
        let displayTickMainRelayFPS: Double
        let displayTickFPS: Double
        let presentationPassFPS: Double
        let presentationEligibleFPS: Double
        let submitAttemptFPS: Double
        let layerEnqueueFPS: Double
        let uniqueLayerEnqueueFPS: Double
        let visibleFrameFPS: Double
        let visibleFrameCadenceKnown: Bool
        let visiblePresentationStallCount: UInt64
        let visibleWorstPresentationGapMs: Double
        let visibleFrameIntervalP95Ms: Double
        let visibleFrameIntervalP99Ms: Double
        let visibleFrameIntervalMaxMs: Double
        let repeatedSourceFrameCount: UInt64
        let framesSubmittedPerPassAverage: Double
        let framesSubmittedPerPassMax: UInt64
        let pendingFrameCount: Int
        let unsubmittedPendingFrameCount: Int
        let retainedSubmittedFrameCount: Int
        let pendingFrameAgeMs: Double
        let oldestUnsubmittedAgeMs: Double
        let newestUnsubmittedAgeMs: Double
        let overwrittenPendingFrames: UInt64
        let renderStoreOverwriteFPS: Double
        let lowestLatencyFreshBacklogDrops: UInt64
        let lateFrameDrops: UInt64
        let coalescedBeforeSubmitCount: UInt64
        let duplicateRemoteTimestampCount: UInt64
        let correctedStreamTimestampCount: UInt64
        let displayLayerNotReadyCount: UInt64
        let sampleBufferRendererNotReadyCount: UInt64
        let displayImmediatelySubmittedCount: UInt64
        let rendererReadyDrainPassCount: UInt64
        let rendererReadyDrainSubmittedCount: UInt64
        let rendererReadyRearmCount: UInt64
        let repeatedFrameCount: UInt64
        let displayTickNoFrameCount: UInt64
        let tickNoEligibleFrameCount: UInt64
        let frameArrivedAfterNoFrameTickCount: UInt64
        let frameArrivalFallbackCount: UInt64
        let frameArrivalFallbackScheduledCount: UInt64
        let frameArrivalFallbackSubmittedCount: UInt64
        let noFrameTickToFrameArrivalMaxMs: Double
        let missedVSyncCount: UInt64
        let smoothestOneFrameHoldCount: UInt64
        let displayCadenceBelowSourceCount: UInt64
        let displayTickIntervalP95Ms: Double
        let displayTickIntervalP99Ms: Double
        let playoutDelayFrames: Int
        let presentationStallCount: UInt64
        let worstPresentationGapMs: Double
        let frameIntervalP95Ms: Double
        let frameIntervalP99Ms: Double
        let frameIntervalMaxMs: Double
        let displayTickIntervalMaxMs: Double
        let displayTickMainDelayMaxMs: Double
        let renderWorkerSubmitDelayMaxMs: Double
        let renderStoreClearCount: UInt64
        let renderGenerationBumpCount: UInt64
        let renderMemoryTrimClearCount: UInt64
        let presenterTimingResetCount: UInt64
        let displayLayerLivenessResetCount: UInt64
        let presentationRecoveryRequestCount: UInt64
        let presentationRecoveryHandlerDispatchCount: UInt64
        let lastRenderGenerationBumpReason: String?
        let lastPresentationRecoveryOutcome: String?
        let decodeHealthy: Bool
        let activeJitterHoldMs: Int
        let decodeBacklogFrames: Int
        let decodeSubmissionInFlightCount: Int
        let decodeSubmissionLimit: Int
        let reassemblerPendingFrameCount: Int
        let reassemblerPendingKeyframeCount: Int
        let reassemblerPendingBytes: Int
        let frameBufferPoolRetainedBytes: Int
        let reassemblerBudgetEvictions: UInt64
        let decoderOutputPixelFormat: String?
        let usingHardwareDecoder: Bool?
    }

    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID
    nonisolated let diagnosticsBuffer = MirageStreamingDiagnosticsBuffer()

    /// HEVC decoder for this stream
    let decoder: VideoDecoder
    var preferredDecoderColorDepth: MirageStreamColorDepth = .standard
    var preferredDecoderBitDepth: MirageVideoBitDepth {
        preferredDecoderColorDepth.bitDepth
    }

    /// Frame reassembler for this stream
    let reassembler: FrameReassembler

    /// Current resize state
    var resizeState: ResizeState = .idle

    /// Last sent resize parameters for deduplication
    var lastSentAspectRatio: CGFloat = 0
    var lastSentRelativeScale: CGFloat = 0
    var lastSentPixelSize: CGSize = .zero

    /// Debounce delay for resize events
    static let resizeDebounceDelay: Duration = .milliseconds(200)

    /// Timeout for resize confirmation
    static let resizeTimeout: Duration = .seconds(2)

    /// Initial keyframe retry interval while decoder is unhealthy.
    static let keyframeRecoveryInitialInterval: Duration = .milliseconds(250)
    /// Secondary keyframe retry interval while decoder is unhealthy.
    static let keyframeRecoverySecondaryInterval: Duration = .milliseconds(500)
    /// Steady-state keyframe retry interval while decoder is unhealthy.
    static let keyframeRecoverySteadyInterval: Duration = .seconds(1)
    /// Maximum keyframe retries before escalating to a single hard reset.
    static let activeRecoveryMaxKeyframeAttempts = 3
    /// Grace period to let promotion continue with forward P-frames before forcing recovery.
    static let tierPromotionProbeDelay: Duration = .milliseconds(250)
    /// Global keyframe retry limiter (max 2 requests/sec).
    static let keyframeRecoveryRetryInterval: CFAbsoluteTime = 0.5
    /// Minimum spacing between soft recoveries to avoid keyframe recovery storms.
    static let softRecoveryMinimumInterval: CFAbsoluteTime = 1.0
    /// Minimum spacing between hard recoveries to avoid repeated full pipeline resets.
    static let hardRecoveryMinimumInterval: CFAbsoluteTime = 2.5
    /// Escalate decode-threshold recovery to a full reset only after repeated failures.
    static let decodeRecoveryEscalationWindow: CFAbsoluteTime = 8.0
    static let decodeRecoveryEscalationThreshold: Int = 3

    /// Duration without decoded frame presentation progress before recovery is requested.
    static let freezeTimeout: CFAbsoluteTime = 1.25
    static let memoryBudgetRecoveryDelay: Duration = .milliseconds(500)

    /// Interval for checking freeze state.
    static let freezeCheckInterval: Duration = .milliseconds(250)
    static let freezeRecoveryCooldown: CFAbsoluteTime = 3.0
    static let freezeRecoveryEscalationThreshold: Int = 2

    /// Maximum number of compressed frames buffered ahead of decode.
    static let maxQueuedFrames: Int = 6
    /// Start recovery before the decode queue reaches the hard admission bound.
    static let decodeQueueRecoveryThreshold: Int = 5
    /// Temporary headroom while VideoToolbox creates the first session and the renderer becomes visible.
    static let smoothestStartupBurstMaxQueuedFrames: Int = 18
    static let smoothestStartupBurstDecodeQueueRecoveryThreshold: Int = 16
    static let lowestLatencyStartupBurstMaxQueuedFrames: Int = 10
    static let lowestLatencyStartupBurstDecodeQueueRecoveryThreshold: Int = 8
    /// Recovery keyframes can briefly refill the queue before presentation stabilization catches up.
    static let smoothestRecoveryStabilizationMaxQueuedFrames: Int = 12
    static let smoothestRecoveryStabilizationDecodeQueueRecoveryThreshold: Int = 10
    static let lowestLatencyRecoveryStabilizationMaxQueuedFrames: Int = 8
    static let lowestLatencyRecoveryStabilizationDecodeQueueRecoveryThreshold: Int = 6
    /// Poll interval while waiting for the first presented frame after startup/reset/resize.
    static let firstPresentedFramePollInterval: Duration = .milliseconds(8)
    /// Interval for progress logs while waiting on first-frame presentation.
    static let firstPresentedFrameWaitLogInterval: CFAbsoluteTime = 0.5
    /// Grace period before issuing bootstrap recovery while initial startup has no presentation progress.
    static let startupFirstPresentedFrameBootstrapRecoveryGrace: CFAbsoluteTime = 5.0
    /// Grace period before issuing bootstrap recovery after an established stream is reset.
    static let recoveryFirstPresentedFrameBootstrapRecoveryGrace: CFAbsoluteTime = 1.0
    /// Treat startup as packet-starved when no recent packets arrive inside this window.
    static let firstPresentedFramePacketStallThreshold: CFAbsoluteTime = 0.35
    /// Cooldown between bootstrap recovery probes while awaiting the first presented frame.
    static let firstPresentedFrameRecoveryCooldown: CFAbsoluteTime = 1.0
    /// Escalate to a hard recovery after a single bounded bootstrap request stalls again.
    static let firstPresentedFrameHardRecoveryThreshold: Int = 2
    /// Maximum number of startup hard recoveries before the stream is failed terminally.
    static let startupHardRecoveryLimit: Int = 1
    static let liveRecoveryHardRecoveryWindow: CFAbsoluteTime = 20.0
    static let liveRecoveryHardRecoveryLimit: Int = 2
    static let startupBurstRecoveryEscalationHoldoff: CFAbsoluteTime = 3.0
    static let recoveryStabilizationDecodedFrameThreshold: Int = 3
    static let recoveryStabilizationPresentedFrameThreshold: Int = 3
    static let recoveryStabilizationLogInterval: CFAbsoluteTime = 0.5

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
        latestCursor: MirageRenderCursor,
        baselineCursor: MirageRenderCursor
    ) -> BootstrapFirstFrameRecoveryAction {
        guard hasPackets else { return .hardRecovery }
        guard latestCursor.isAfter(baselineCursor) || awaitingKeyframe else { return .hardRecovery }
        return awaitingKeyframe ? .requestKeyframe : .hardRecovery
    }

    nonisolated static func shouldAttemptRendererRecoveryBeforeBootstrapReset(
        pendingFrameCount: Int,
        submittedCursor: MirageRenderCursor,
        baselineCursor: MirageRenderCursor,
        rendererRecoveryAttempts: Int
    )
    -> Bool {
        pendingFrameCount > 0 &&
            !submittedCursor.hasSubmittedFrame &&
            !baselineCursor.hasSubmittedFrame &&
            rendererRecoveryAttempts == 0
    }

    /// Minimum interval between decode backpressure drop logs.
    static let queueDropLogInterval: CFAbsoluteTime = 1.0
    static let backpressureLogCooldown: CFAbsoluteTime = 1.0
    static let recoveryRequestDispatchCooldown: CFAbsoluteTime = 0.5
    static let backgroundDecodeErrorLogInterval: CFAbsoluteTime = 2.0
    static let decodeErrorLogInterval: CFAbsoluteTime = 15.0
    static let decodeErrorEscalationThreshold: Int = 3
    static let postResizeDecodeErrorGraceInterval: CFAbsoluteTime = 0.75
    static let postResizeDecodeRecoverySuccessThreshold: Int = 3
    static let decodeSubmissionStressThreshold: Double = 0.80
    static let decodeSubmissionHealthyThreshold: Double = 0.95
    static let decodeSubmissionStressWindows: Int = 2
    static let decodeSubmissionHealthyWindows: Int = 3
    static let decodeSubmissionDecodeBoundGapFPS: Double = 2.5
    static let decodeSubmissionSourceBoundGapFPS: Double = 1.0
    static let adaptiveJitterHoldMaxMs: Int = 8
    static let adaptiveJitterStressThreshold: Double = 0.88
    static let adaptiveJitterStressWindows: Int = 2
    static let adaptiveJitterStableWindows: Int = 4
    static let adaptiveJitterStepUpMs: Int = 2
    static let adaptiveJitterStepDownMs: Int = 1

    /// Pending resize debounce task
    var resizeDebounceTask: Task<Void, Never>?

    /// Task that periodically requests keyframes during decoder recovery
    var keyframeRecoveryTask: Task<Void, Never>?
    var keyframeRecoveryAttempt: Int = 0
    var recoveryCoordinator = RecoveryCoordinator()
    var realtimeMediaSession: RealtimeMediaSession
    /// One-shot probe that verifies decode/presentation progress after passive->active promotion.
    var tierPromotionProbeTask: Task<Void, Never>?
    var memoryBudgetRecoveryTask: Task<Void, Never>?
    var lastRecoveryRequestTime: CFAbsoluteTime = 0

    /// Whether we've decoded at least one frame.
    var hasDecodedFirstFrame = false
    /// Whether we've presented at least one frame.
    var hasPresentedFirstFrame = false
    var firstPresentedFrameTime: CFAbsoluteTime = 0
    /// True while hard recovery must wait for a new render-store submission sequence.
    var presentationProgressRequiresSequenceAdvance = false
    /// True while post-resize recovery remains active.
    var awaitingFirstFrameAfterResize = false
    /// True while post-resize decode admission should still drop non-keyframes.
    var awaitingFirstPresentedFrameAfterResize = false
    /// Suppresses immediate post-resize decode-threshold recovery until presentation has a chance to resume.
    var postResizeDecodeErrorGraceDeadline: CFAbsoluteTime = 0
    /// Monotonic identifier for the current post-resize recovery episode.
    var postResizeRecoveryEpisodeID: UInt64 = 0
    /// Decoder-confirmed post-resize recovery streak progress for the active resize episode.
    var postResizeDecodeRecoverySuccessCount: Int = 0
    /// True while UI gating waits for the first newly presented frame.
    var awaitingFirstPresentedFrame = false
    /// Startup watchdog vs recovery watchdog mode for the first-frame awaiter.
    var firstPresentedFrameAwaitMode: FirstPresentedFrameAwaitMode = .startup
    /// Last render cursor at the moment first-frame presentation waiting was armed.
    var firstPresentedFrameBaselineCursor: MirageRenderCursor = .zero
    /// Human-readable label describing why the first-frame wait was armed.
    var firstPresentedFrameWaitReason: String?
    /// Start time for first-frame presentation wait latency logs.
    var firstPresentedFrameWaitStartTime: CFAbsoluteTime = 0
    /// Last time a first-frame presentation wait progress log was emitted.
    var firstPresentedFrameLastWaitLogTime: CFAbsoluteTime = 0
    /// Last time first-frame startup watchdog requested bootstrap recovery.
    var firstPresentedFrameLastRecoveryRequestTime: CFAbsoluteTime = 0
    /// Number of bootstrap recovery actions dispatched in the current first-frame wait window.
    var firstPresentedFrameRecoveryAttemptCount: Int = 0
    /// Number of renderer recovery attempts dispatched while waiting for first presentation.
    var firstPresentedFrameRendererRecoveryAttemptCount: Int = 0
    /// Number of full hard recoveries consumed while still waiting on the first presented frame.
    var startupHardRecoveryCount: Int = 0
    /// True after the controller has concluded startup recovery cannot succeed.
    var hasTriggeredTerminalStartupFailure = false
    var liveRecoveryHardRecoveryTimestamps: [CFAbsoluteTime] = []
    var hasTriggeredTerminalLiveRecoveryFailure = false
    var recoveryStabilizationBaselineCursor: MirageRenderCursor = .zero
    var recoveryStabilizationDecodedFrameCount: Int = 0
    var lastRecoveryStabilizationLogTime: CFAbsoluteTime = 0
    /// Bounded queue of frames waiting to be decoded.
    var queuedFrames = MirageRingBuffer<FrameData>(minimumCapacity: 32)
    /// Frames received from callback tasks before their ordered enqueue slot is ready.
    var pendingOrderedFrames: [UInt64: FrameData] = [:]
    var nextExpectedEnqueueOrder: UInt64 = 0
    private let enqueueOrderAllocator = FrameEnqueueOrderAllocator()
    var framePipelineGeneration: UInt64 = 0
    var lastRenderHostEpoch: UInt16?

    /// Continuation resumed when the decode task is waiting for a frame.
    var dequeueContinuation: CheckedContinuation<FrameData?, Never>?

    /// Task that processes frames from the stream in FIFO order
    /// This ensures frames are decoded sequentially, preventing P-frame decode errors
    var frameProcessingTask: Task<Void, Never>?
    /// Task that waits for first frame presentation progress before unblocking UI state.
    var firstPresentedFrameTask: Task<Void, Never>?

    var queueDropsSinceLastLog: UInt64 = 0
    var lastQueueDropLogTime: CFAbsoluteTime = 0
    var decodeRecoveryEscalationTimestamps: [CFAbsoluteTime] = []
    var lastBackgroundDecodeErrorSignature: String?
    var lastBackgroundDecodeErrorLogTime: CFAbsoluteTime = 0
    var consecutiveDecodeErrors: Int = 0
    var lastDecodeErrorSignature: String?
    var lastDecodeErrorLogTime: CFAbsoluteTime = 0
    var lastRecoveryRequestDispatchTime: CFAbsoluteTime = 0
    var lastSoftRecoveryRequestTime: CFAbsoluteTime = 0
    var lastHardRecoveryStartTime: CFAbsoluteTime = 0
    var lastBackpressureLogTime: CFAbsoluteTime = 0
    var streamCadenceTarget = MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 60)
    var streamCadenceClock = MirageStreamCadenceClock(targetFPS: 60)
    var decodeSchedulerTargetFPS: Int = 60
    var decodeSubmissionBaselineLimit: Int = 1
    var decodeSubmissionStressStreak: Int = 0
    var decodeSubmissionHealthyStreak: Int = 0
    var currentDecodeSubmissionLimit: Int = 1
    var lastDecodeSubmissionConstraintWasSourceBound: Bool?
    var lastSourceBoundDiagnosticSignature: String?
    var latestHostMetricsMessage: StreamMetricsMessage?
    var latestHostCadencePressureSample: HostCadencePressureDiagnosticSample?
    var latestRenderTelemetrySnapshot: MirageRenderStreamStore.RenderTelemetrySnapshot?
    var lastStreamingAnomalyDiagnosticSignature: String?
    var lastStreamingAnomalyDiagnosticTime: CFAbsoluteTime = 0
    var presentationTier: StreamPresentationTier = .activeLive
    var isRunning = false
    var isStopping = false

    let metricsTracker = ClientFrameMetricsTracker()
    var metricsTask: Task<Void, Never>?
    var mediaFeedbackTask: Task<Void, Never>?
    var mediaFeedbackSequence: UInt64 = 0
    var mediaFeedbackSuspended = false
    static let streamingAnomalyLogCooldown: CFAbsoluteTime = 5.0
    static let metricsDispatchInterval: Duration = .milliseconds(500)
    static let mediaFeedbackDispatchInterval: Duration = .milliseconds(75)
    let awdlExperimentEnabled: Bool = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    var awdlTransportActive: Bool = false
    var adaptiveJitterHoldMs: Int = 0
    var adaptiveJitterStressStreak: Int = 0
    var adaptiveJitterStableStreak: Int = 0

    var lastDecodedFrameTime: CFAbsoluteTime = 0
    var lastPresentedCursorObserved: MirageRenderCursor = .zero
    var lastPresentedProgressTime: CFAbsoluteTime = 0
    var lastFreezeRecoveryTime: CFAbsoluteTime = 0
    var consecutiveFreezeRecoveries: Int = 0
    var freezeMonitorTask: Task<Void, Never>?
    private let nowProvider: @Sendable () -> CFAbsoluteTime
    private let applicationForegroundProvider: @Sendable () async -> Bool

    // MARK: - Callbacks

    /// Called when resize state changes
    private(set) var onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)?

    /// Called when a keyframe should be requested from host
    private(set) var onKeyframeNeeded: (@MainActor @Sendable () -> Void)?

    /// Called when a resize event should be sent to host
    private(set) var onResizeEvent: (@MainActor @Sendable (ResizeEvent) -> Void)?

    /// Called when a frame is decoded (for delegate notification)
    /// This callback notifies AppState that a frame was decoded for UI state tracking.
    /// Does NOT pass the pixel buffer (CVPixelBuffer isn't Sendable).
    /// The delegate should read from MirageRenderStreamStore if it needs the actual frame.
    private(set) var onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)?
    /// Called with receiver-side realtime media feedback for host-owned adaptation.
    private(set) var onMediaFeedback: (@Sendable (ReceiverMediaFeedbackMessage) -> Void)?

    /// Called when the first frame is decoded for a stream.
    private(set) var onFirstFrameDecoded: (@MainActor @Sendable () -> Void)?
    /// Called when a decoded frame arrives during a post-resize transition.
    private(set) var onPostResizeFrameDecoded: (@MainActor @Sendable () -> Void)?
    /// Called when the first frame is presented for a stream.
    private(set) var onFirstFramePresented: (@MainActor @Sendable () -> Void)?

    /// Called when freeze monitoring records a typed stall event.
    private(set) var onStallEvent: (@MainActor @Sendable (RuntimeWorkloadSafetyStallEvent) -> Void)?
    /// Called when client recovery state changes.
    private(set) var onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)?
    /// Called when bounded startup recovery is exhausted before the first frame is presented.
    private(set) var onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)?
    /// Called when bounded live recovery is exhausted after an established stream regresses.
    private(set) var onTerminalLiveRecoveryFailure: (@MainActor @Sendable (TerminalLiveRecoveryFailure) -> Void)?

    /// Last recovery status delivered to the app layer.
    var clientRecoveryStatus: MirageStreamClientRecoveryStatus = .idle

    /// Set callbacks for stream events
    func setCallbacks(
        onKeyframeNeeded: (@MainActor @Sendable () -> Void)?,
        onResizeEvent: (@MainActor @Sendable (ResizeEvent) -> Void)?,
        onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)? = nil,
        onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil,
        onMediaFeedback: (@Sendable (ReceiverMediaFeedbackMessage) -> Void)? = nil,
        onFirstFrameDecoded: (@MainActor @Sendable () -> Void)? = nil,
        onPostResizeFrameDecoded: (@MainActor @Sendable () -> Void)? = nil,
        onFirstFramePresented: (@MainActor @Sendable () -> Void)? = nil,
        onStallEvent: (@MainActor @Sendable (RuntimeWorkloadSafetyStallEvent) -> Void)? = nil,
        onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)? = nil,
        onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)? = nil,
        onTerminalLiveRecoveryFailure: (@MainActor @Sendable (TerminalLiveRecoveryFailure) -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeEvent = onResizeEvent
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
        self.onMediaFeedback = onMediaFeedback
        self.onFirstFrameDecoded = onFirstFrameDecoded
        self.onPostResizeFrameDecoded = onPostResizeFrameDecoded
        self.onFirstFramePresented = onFirstFramePresented
        self.onStallEvent = onStallEvent
        self.onRecoveryStatusChanged = onRecoveryStatusChanged
        self.onTerminalStartupFailure = onTerminalStartupFailure
        self.onTerminalLiveRecoveryFailure = onTerminalLiveRecoveryFailure
    }

    func setClientRecoveryStatus(_ status: MirageStreamClientRecoveryStatus) async {
        guard clientRecoveryStatus != status else { return }
        clientRecoveryStatus = status
        realtimeMediaSession.setRecoveryState(Self.mediaFeedbackRecoveryState(for: status))
        guard let onRecoveryStatusChanged else { return }
        await MainActor.run {
            onRecoveryStatusChanged(status)
        }
    }

    nonisolated static func mediaFeedbackRecoveryState(
        for status: MirageStreamClientRecoveryStatus
    ) -> MirageMediaFeedbackRecoveryState {
        switch status {
        case .idle:
            .idle
        case .startup:
            .startup
        case .tierPromotionProbe:
            .tierPromotionProbe
        case .keyframeRecovery:
            .keyframeRecovery
        case .hardRecovery:
            .hardRecovery
        case .postResizeAwaitingFirstFrame:
            .postResizeAwaitingFirstFrame
        }
    }

    // MARK: - Initialization

    /// Create a new stream controller
    init(
        streamID: StreamID,
        maxPayloadSize: Int,
        nowProvider: @escaping @Sendable () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
        applicationForegroundProvider: (@Sendable () async -> Bool)? = nil
    ) {
        self.streamID = streamID
        decoder = VideoDecoder()
        reassembler = FrameReassembler(streamID: streamID, maxPayloadSize: maxPayloadSize)
        realtimeMediaSession = RealtimeMediaSession(streamID: streamID, targetFrameRate: 60)
        self.nowProvider = nowProvider
        if let applicationForegroundProvider {
            self.applicationForegroundProvider = applicationForegroundProvider
        } else {
            self.applicationForegroundProvider = {
                await StreamController.defaultApplicationForegroundProvider()
            }
        }
    }

    func currentTime() -> CFAbsoluteTime {
        nowProvider()
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

    /// Start the controller - sets up decoder and reassembler callbacks
    func start() async {
        isStopping = false
        isRunning = true
        await GlobalDecodeBudgetController.shared.register(streamID: streamID, tier: presentationTier)
        lastDecodedFrameTime = 0
        lastPresentedCursorObserved = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        lastRecoveryRequestDispatchTime = 0
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        recoveryCoordinator.reset()
        realtimeMediaSession = RealtimeMediaSession(streamID: streamID, targetFrameRate: decodeSchedulerTargetFPS)
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
        liveRecoveryHardRecoveryTimestamps.removeAll(keepingCapacity: false)
        hasTriggeredTerminalLiveRecoveryFailure = false
        firstPresentedFrameTime = 0
        resetRecoveryStabilizationTracking()
        cancelMemoryBudgetRecoveryTask()
        await setClientRecoveryStatus(.idle)
        stopFreezeMonitor()
        let submissionSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        lastPresentedCursorObserved = submissionSnapshot.visibleCursor
        lastPresentedProgressTime = submissionSnapshot.visibleSubmittedTime

        // Set up error recovery - request keyframe when decode errors exceed threshold
        await decoder.setErrorThresholdHandler({ [weak self] in
            guard let self else { return }
            Task {
                await self.handleDecodeErrorThresholdSignal()
            }
        }, onRecovery: { [weak self] in
            guard let self else { return }
            Task {
                await self.handleDecoderRecoverySignal()
            }
        })

        // Set up dimension change handler - reset reassembler when dimensions change
        let capturedStreamID = streamID
        await decoder.setDimensionChangeHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.resetReassemblerForDimensionChange(streamID: capturedStreamID)
            }
        }

        // Set up frame handler
        let metricsTracker = metricsTracker
        await decoder.startDecoding { [weak self] (
            pixelBuffer: CVPixelBuffer,
            presentationTime: CMTime,
            contentRect: CGRect,
            context: MirageVideoDecodeFrameContext
        ) in
            let decodeTime = CFAbsoluteTimeGetCurrent()
            let handledByUpscaler = false
            if !handledByUpscaler {
                let enqueueResult = MirageRenderStreamStore.shared.enqueue(
                    pixelBuffer: pixelBuffer,
                    contentRect: contentRect,
                    decodeTime: decodeTime,
                    presentationTime: presentationTime,
                    remotePresentationTime: context.remotePresentationTime,
                    generation: context.renderGeneration,
                    hostEpoch: context.hostEpoch,
                    dimensionToken: context.dimensionToken,
                    frameNumber: context.frameNumber,
                    queueEpoch: context.queueEpoch,
                    timeline: context.timeline,
                    for: capturedStreamID
                )
                guard enqueueResult.didEnqueue else { return }
            }

            let decodedFrameRecord = metricsTracker.recordDecodedFrame(now: decodeTime)
            self?.diagnosticsBuffer.recordDecodeGap(
                streamID: capturedStreamID,
                gapMs: decodedFrameRecord.gapMs,
                now: decodeTime
            )
            Task { [weak self] in
                guard let self else { return }
                if decodedFrameRecord.isFirstFrame { await self.markFirstFrameDecoded() }
                await self.recordDecodedFrame()
            }
        }

        await startFrameProcessingPipeline()
        if presentationTier == .activeLive {
            await armFirstPresentedFrameAwaiter(reason: "stream-start")
        } else {
            stopFirstPresentedFrameMonitor()
        }
        startMetricsReporting()
        startMediaFeedbackReporting()
    }

    func startFrameProcessingPipeline() async {
        framePipelineGeneration &+= 1
        let activePipelineGeneration = framePipelineGeneration
        finishFrameQueue()
        queueDropsSinceLastLog = 0
        lastQueueDropLogTime = 0
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        lastPresentedCursorObserved = MirageRenderStreamStore.shared.baselineCursor(for: streamID)
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        metricsTracker.reset()
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
        await decoder.setDecodeSubmissionLimit(
            limit: decodeSubmissionBaselineLimit,
            reason: "stream pipeline start"
        )
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        pendingOrderedFrames.removeAll(keepingCapacity: false)

        // Start the frame processing task - single task processes all frames sequentially
        let capturedDecoder = decoder
        let decodeBudgetController = GlobalDecodeBudgetController.shared
        frameProcessingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let frame = await dequeueFrame() else { break }
                defer { frame.releaseBuffer() }
                guard let lease = await decodeBudgetController.acquire(streamID: self.streamID) else {
                    continue
                }
                do {
                    let decodeSubmitTime = CFAbsoluteTimeGetCurrent()
                    try await capturedDecoder.decodeFrame(
                        frame.data,
                        presentationTime: frame.presentationTime,
                        isKeyframe: frame.isKeyframe,
                        contentRect: frame.contentRect,
                        context: frame.decodeContext(submittedAt: decodeSubmitTime)
                    )
                } catch {
                    await recordDecodeFailure(error)
                }
                await decodeBudgetController.release(lease)
            }
        }

        // Set up reassembler callback - enqueue frames for ordered processing
        let metricsTracker = metricsTracker
        let diagnosticsBuffer = diagnosticsBuffer
        let enqueueOrderAllocator = enqueueOrderAllocator
        let reassemblerStreamID = streamID
        let reassemblerHandler: @Sendable (
            StreamID,
            Data,
            Bool,
            UInt32,
            UInt64,
            UInt16,
            UInt16,
            CGRect,
            FrameTimeline,
            @escaping @Sendable () -> Void
        ) -> Void = { [weak self] _, frameData, isKeyframe, frameNumber, timestamp, epoch, dimensionToken, contentRect, timeline, releaseBuffer in
                let receivedRecord = metricsTracker.recordReceivedFrame()
                diagnosticsBuffer.recordFrameArrivalGap(
                    streamID: reassemblerStreamID,
                    gapMs: receivedRecord.gapMs,
                    frameSizeBytes: frameData.count,
                    isKeyframe: isKeyframe
                )
                let ticket = enqueueOrderAllocator.allocate(pipelineGeneration: activePipelineGeneration)

                Task {
                    guard let self else {
                        releaseBuffer()
                        return
                    }
                    await self.enqueueReassembledFrame(
                        data: frameData,
                        frameNumber: frameNumber,
                        remoteTimestamp: timestamp,
                        isKeyframe: isKeyframe,
                        hostEpoch: epoch,
                        dimensionToken: dimensionToken,
                        contentRect: contentRect,
                        timeline: timeline,
                        releaseBuffer: releaseBuffer,
                        ticket: ticket
                    )
                }
            }
        reassembler.setFrameHandler(reassemblerHandler)
        reassembler.setFrameLossHandler { [weak self] _, reason in
            guard let self else { return }
            Task {
                await self.handleFrameLossSignal(reason: reason)
            }
        }
    }

    private func resetReassemblerForDimensionChange(streamID capturedStreamID: StreamID) {
        reassembler.reset()
        streamCadenceClock.reset(targetFPS: streamCadenceTarget.sourceFPS)
        MirageLogger.client("Reassembler reset due to dimension change for stream \(capturedStreamID)")
    }

    func stopFrameProcessingPipeline() {
        framePipelineGeneration &+= 1
        finishFrameQueue()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
    }

    func recordDecodeSuccessIfNeeded() {
        guard isRunning, !isStopping else {
            lastBackgroundDecodeErrorSignature = nil
            lastBackgroundDecodeErrorLogTime = 0
            consecutiveDecodeErrors = 0
            lastDecodeErrorSignature = nil
            lastDecodeErrorLogTime = 0
            return
        }
        guard consecutiveDecodeErrors > 0 ||
            lastBackgroundDecodeErrorSignature != nil ||
            lastBackgroundDecodeErrorLogTime > 0 else { return }
        MirageLogger.debug(
            .client,
            "Decode pipeline recovered after \(consecutiveDecodeErrors) consecutive error(s)"
        )
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
    }

    private func recordDecodeFailure(_ error: Error) async {
        guard isRunning, !isStopping else { return }
        guard !hasTriggeredTerminalStartupFailure else { return }
        guard !hasTriggeredTerminalLiveRecoveryFailure else { return }

        if Self.shouldSuppressDecodeFailureRecovery(
            isApplicationForeground: await applicationForegroundProvider()
        ) {
            recordBackgroundDecodeFailureIfNeeded(error)
            consecutiveDecodeErrors = 0
            lastDecodeErrorSignature = nil
            lastDecodeErrorLogTime = 0
            return
        }

        let metadata = LoomDiagnosticsErrorMetadata(error: error)
        let signature = "\(metadata.domain):\(metadata.code)"
        let now = currentTime()
        consecutiveDecodeErrors += 1
        let logMessage = Self.decodeFailureLogMessage(for: error, attempt: consecutiveDecodeErrors)
        let shouldElevate = Self.shouldElevateDecodeFailure(
            consecutiveDecodeErrors: consecutiveDecodeErrors,
            signature: signature,
            previousSignature: lastDecodeErrorSignature,
            lastLogTime: lastDecodeErrorLogTime,
            now: now,
            recoveryActionable: shouldAttemptDecodeErrorRecovery(now: now)
        )

        if shouldElevate {
            MirageLogger.error(
                .client,
                error: error,
                message: logMessage
            )
            lastDecodeErrorSignature = signature
            lastDecodeErrorLogTime = now
        } else {
            let threshold = Self.decodeErrorEscalationThreshold
            if consecutiveDecodeErrors < threshold {
                MirageLogger.debug(
                    .client,
                    "Decode error observed before escalation threshold (attempt \(consecutiveDecodeErrors)/\(threshold), signature \(signature))"
                )
            } else {
                let recoveryActionable = shouldAttemptDecodeErrorRecovery(now: now)
                if recoveryActionable {
                    MirageLogger.debug(
                        .client,
                        "\(logMessage) [suppressed-repeat]"
                    )
                } else {
                    MirageLogger.debug(
                        .client,
                        "\(logMessage) [suppressed-until-recovery-actionable]"
                    )
                }
            }
        }
    }

    nonisolated static func shouldSuppressDecodeFailureRecovery(
        isApplicationForeground: Bool
    ) -> Bool {
        !isApplicationForeground
    }

    private func recordBackgroundDecodeFailureIfNeeded(_ error: Error) {
        let metadata = LoomDiagnosticsErrorMetadata(error: error)
        let signature = "\(metadata.domain):\(metadata.code)"
        let now = currentTime()
        let shouldLog = signature != lastBackgroundDecodeErrorSignature ||
            now - lastBackgroundDecodeErrorLogTime >= Self.backgroundDecodeErrorLogInterval

        guard shouldLog else { return }

        lastBackgroundDecodeErrorSignature = signature
        lastBackgroundDecodeErrorLogTime = now
        MirageLogger.client(
            "Decode error while backgrounded; suppressing recovery until foreground " +
                "[\(Self.decodeFailureDiagnosticSummary(for: error))]"
        )
    }

    nonisolated static func decodeFailureLogMessage(for error: Error, attempt: Int) -> String {
        "Decode error (attempt \(attempt)): \(decodeFailureDiagnosticSummary(for: error))"
    }

    nonisolated static func decodeFailureDiagnosticSummary(for error: Error) -> String {
        var components: [String] = []
        appendDiagnosticSummary(for: error, label: "error", into: &components)

        if let nsUnderlyingError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            appendDiagnosticSummary(for: nsUnderlyingError, label: "nsUnderlying", into: &components)
        }

        return components.joined(separator: " | ")
    }

    private nonisolated static func appendDiagnosticSummary(
        for error: Error,
        label: String,
        into components: inout [String]
    ) {
        let metadata = LoomDiagnosticsErrorMetadata(error: error)
        let localizedDescription = sanitizedDiagnosticDescription(error.localizedDescription)
        components.append(
            "\(label){type=\(metadata.typeName),domain=\(metadata.domain),code=\(metadata.code),description=\(localizedDescription)}"
        )

        if let mirageError = error as? MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError),
                 let .encodingError(underlyingError),
                 let .decodingError(underlyingError):
                appendNestedDiagnosticSummary(
                    for: underlyingError,
                    parentLabel: label,
                    into: &components
                )
            case let .protocolError(message):
                components.append("\(label).protocol{\(sanitizedDiagnosticDescription(message))}")
            case let .captureSetupFailed(message):
                components.append("\(label).captureSetup{\(sanitizedDiagnosticDescription(message))}")
            case let .connectionRejected(rejection):
                components.append("\(label).rejection{\(rejection.reason.rawValue)}")
            case .alreadyAdvertising,
                 .notAdvertising,
                 .authenticationFailed,
                 .streamNotFound,
                 .windowNotFound,
                 .permissionDenied,
                 .timeout:
                break
            }
        }
    }

    private nonisolated static func appendNestedDiagnosticSummary(
        for error: Error,
        parentLabel: String,
        into components: inout [String]
    ) {
        let metadata = LoomDiagnosticsErrorMetadata(error: error)
        let localizedDescription = sanitizedDiagnosticDescription(error.localizedDescription)
        components.append(
            "\(parentLabel).underlying{type=\(metadata.typeName),domain=\(metadata.domain),code=\(metadata.code),description=\(localizedDescription)}"
        )
    }

    private nonisolated static func sanitizedDiagnosticDescription(_ description: String) -> String {
        description
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func shouldElevateDecodeFailure(
        consecutiveDecodeErrors: Int,
        signature: String,
        previousSignature: String?,
        lastLogTime: CFAbsoluteTime,
        now: CFAbsoluteTime,
        recoveryActionable: Bool
    ) -> Bool {
        guard recoveryActionable else { return false }
        guard consecutiveDecodeErrors >= decodeErrorEscalationThreshold else { return false }
        if consecutiveDecodeErrors == decodeErrorEscalationThreshold {
            return true
        }
        if signature != previousSignature {
            return true
        }
        return now - lastLogTime >= decodeErrorLogInterval
    }

    private func enqueueReassembledFrame(
        data: Data,
        frameNumber: UInt32,
        remoteTimestamp: UInt64,
        isKeyframe: Bool,
        hostEpoch: UInt16,
        dimensionToken: UInt16,
        contentRect: CGRect,
        timeline: FrameTimeline,
        releaseBuffer: @escaping @Sendable () -> Void,
        ticket: FrameQueueTicket
    )
    async {
        guard ticket.pipelineGeneration == framePipelineGeneration,
              ticket.queueEpoch == enqueueOrderAllocator.currentQueueEpoch() else {
            releaseBuffer()
            return
        }

        let renderGeneration = renderGenerationForDecodedFrame(hostEpoch: hostEpoch)
        let remotePresentationTime = CMTime(value: CMTimeValue(remoteTimestamp), timescale: 1_000_000_000)
        let timing = streamCadenceClock.timing(
            frameNumber: frameNumber,
            remotePresentationTime: remotePresentationTime,
            isKeyframe: isKeyframe
        )
        MirageRenderStreamStore.shared.recordFrameTimingDiagnostics(
            for: streamID,
            duplicateRemoteTimestamp: timing.duplicateRemoteTimestamp,
            correctedStreamTimestamp: timing.correctedStreamTimestamp
        )
        let frame = FrameData(
            data: data,
            frameNumber: frameNumber,
            remotePresentationTime: remotePresentationTime,
            presentationTime: timing.streamPresentationTime,
            isKeyframe: isKeyframe,
            contentRect: contentRect,
            renderGeneration: renderGeneration,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            timeline: timeline,
            queueTicket: ticket,
            releaseBuffer: releaseBuffer
        )
        await enqueueFrame(frame)
    }

    private func enqueueFrame(_ frame: FrameData)
    async {
        guard frame.queueTicket.pipelineGeneration == framePipelineGeneration,
              frame.queueTicket.queueEpoch == enqueueOrderAllocator.currentQueueEpoch() else {
            frame.releaseBuffer()
            return
        }

        pendingOrderedFrames[frame.queueTicket.order] = frame
        while let nextFrame = pendingOrderedFrames.removeValue(forKey: nextExpectedEnqueueOrder) {
            nextExpectedEnqueueOrder &+= 1
            await enqueueFrameInOrder(nextFrame)
        }
    }

    private func renderGenerationForDecodedFrame(hostEpoch: UInt16) -> UInt64 {
        if let lastRenderHostEpoch, lastRenderHostEpoch != hostEpoch {
            self.lastRenderHostEpoch = hostEpoch
            streamCadenceClock.reset(targetFPS: streamCadenceTarget.sourceFPS)
            return MirageRenderStreamStore.shared.bumpGeneration(
                for: streamID,
                reason: "host-epoch-change"
            )
        }

        if lastRenderHostEpoch == nil {
            lastRenderHostEpoch = hostEpoch
        }
        return MirageRenderStreamStore.shared.currentGeneration(for: streamID)
    }

    func decodeQueueAdmissionLimits(now: CFAbsoluteTime) -> DecodeQueueAdmissionLimits {
        if presentationTier == .activeLive {
            let isStartupBurst = !hasPresentedFirstFrame || isWithinStartupBurstRecoveryHoldoff(now: now)
            if isStartupBurst {
                return streamCadenceTarget.latencyMode == .smoothest
                    ? DecodeQueueAdmissionLimits(
                        recoveryThreshold: Self.smoothestStartupBurstDecodeQueueRecoveryThreshold,
                        hardLimit: Self.smoothestStartupBurstMaxQueuedFrames
                    )
                    : DecodeQueueAdmissionLimits(
                        recoveryThreshold: Self.lowestLatencyStartupBurstDecodeQueueRecoveryThreshold,
                        hardLimit: Self.lowestLatencyStartupBurstMaxQueuedFrames
                    )
            }

            if clientRecoveryStatus == .keyframeRecovery,
               !reassembler.isAwaitingKeyframe(),
               !hasStableRecoveryPresentationProgress() {
                return streamCadenceTarget.latencyMode == .smoothest
                    ? DecodeQueueAdmissionLimits(
                        recoveryThreshold: Self.smoothestRecoveryStabilizationDecodeQueueRecoveryThreshold,
                        hardLimit: Self.smoothestRecoveryStabilizationMaxQueuedFrames
                    )
                    : DecodeQueueAdmissionLimits(
                        recoveryThreshold: Self.lowestLatencyRecoveryStabilizationDecodeQueueRecoveryThreshold,
                        hardLimit: Self.lowestLatencyRecoveryStabilizationMaxQueuedFrames
                    )
            }
        }

        return DecodeQueueAdmissionLimits(
            recoveryThreshold: Self.decodeQueueRecoveryThreshold,
            hardLimit: Self.maxQueuedFrames
        )
    }

    private func enqueueFrameInOrder(_ frame: FrameData) async {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: frame)
            return
        }

        if presentationTier == .passiveSnapshot {
            if !queuedFrames.isEmpty {
                clearQueuedFramesForRecovery()
            }
            queuedFrames.append(frame)
            return
        }

        let admissionLimits = decodeQueueAdmissionLimits(now: currentTime())
        if queuedFrames.count >= admissionLimits.recoveryThreshold {
            let queueDepth = queuedFrames.count
            await performDecodeFreshnessCatchUp(keeping: frame, queueDepth: queueDepth)
            logQueueDropIfNeeded()
            return
        }

        if queuedFrames.count >= admissionLimits.hardLimit {
            let queueDepth = queuedFrames.count
            await performDecodeFreshnessCatchUp(keeping: frame, queueDepth: queueDepth)
            logQueueDropIfNeeded()
            return
        }

        queuedFrames.append(frame)
    }

    func enqueueFrameForRecoveryTesting(
        frameNumber: UInt32,
        isKeyframe: Bool = false,
        releaseBuffer: @escaping @Sendable () -> Void = {}
    ) async {
        let payload = Data([UInt8(truncatingIfNeeded: frameNumber)])
        let frame = FrameData(
            data: payload,
            frameNumber: frameNumber,
            remotePresentationTime: CMTime(value: CMTimeValue(frameNumber), timescale: 120),
            presentationTime: CMTime(value: CMTimeValue(frameNumber), timescale: 120),
            isKeyframe: isKeyframe,
            contentRect: .zero,
            renderGeneration: MirageRenderStreamStore.shared.currentGeneration(for: streamID),
            hostEpoch: 0,
            dimensionToken: 0,
            timeline: FrameTimeline(
                streamID: streamID,
                frameNumber: frameNumber,
                dependencyEpoch: DependencyEpoch(0),
                isKeyframe: isKeyframe,
                encodedByteCount: payload.count,
                fragmentCount: 1
            ),
            queueTicket: FrameQueueTicket(
                pipelineGeneration: framePipelineGeneration,
                queueEpoch: enqueueOrderAllocator.currentQueueEpoch(),
                order: nextExpectedEnqueueOrder
            ),
            releaseBuffer: releaseBuffer
        )
        await enqueueFrameInOrder(frame)
    }

    func queuedFrameSnapshotForTesting() -> (count: Int, firstFrameNumber: UInt32?, lastFrameNumber: UInt32?) {
        (
            queuedFrames.count,
            queuedFrames.first?.frameNumber,
            queuedFrames.last?.frameNumber
        )
    }

    private func performDecodeFreshnessCatchUp(keeping frame: FrameData, queueDepth: Int) async {
        maybeLogDecodeBackpressure(queueDepth: queueDepth)
        let dropped = clearQueuedFramesForFreshnessCatchUp()
        if frame.isKeyframe {
            queuedFrames.append(frame)
            MirageLogger.client(
                "Decode freshness catch-up for stream \(streamID) at depth \(queueDepth); " +
                    "dropped stale queued frames=\(dropped)"
            )
            return
        }

        frame.releaseBuffer()
        recordQueueDrop()
        reassembler.enterKeyframeOnlyMode()
        await decoder.beginRecoveryTracking()
        if presentationTier == .activeLive {
            await startKeyframeRecoveryLoopIfNeeded()
        }
        await requestKeyframeRecovery(reason: .frameLoss)
        MirageLogger.client(
            "Decode freshness catch-up for stream \(streamID) at depth \(queueDepth); " +
                "dropped stale queued frames=\(dropped), rejected dependent frame=\(frame.frameNumber)"
        )
    }

    private func dequeueFrame() async -> FrameData? {
        let frame: FrameData? = if !queuedFrames.isEmpty {
            queuedFrames.popFirst()
        } else {
            await withCheckedContinuation { continuation in
                dequeueContinuation = continuation
            }
        }
        guard frame != nil else { return nil }
        await maybeApplyAdaptiveJitterHold()
        return frame
    }

    private func maybeApplyAdaptiveJitterHold() async {
        guard awdlExperimentEnabled, awdlTransportActive else { return }
        let holdMs = max(0, min(Self.adaptiveJitterHoldMaxMs, adaptiveJitterHoldMs))
        guard holdMs > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int64(holdMs)))
    }

    private func finishFrameQueue() {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: nil)
        }
        let queued = queuedFrames.drain()
        let pending = Array(pendingOrderedFrames.values)
        pendingOrderedFrames.removeAll(keepingCapacity: false)
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        if queued.isEmpty, pending.isEmpty { return }
        let frames = queued + pending
        for frame in frames {
            frame.releaseBuffer()
        }
    }

    @discardableResult
    func clearQueuedFramesForRecovery() -> Int {
        let queued = queuedFrames.drain()
        let pending = Array(pendingOrderedFrames.values)
        pendingOrderedFrames.removeAll(keepingCapacity: false)
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        guard !queued.isEmpty || !pending.isEmpty else { return 0 }
        let frames = queued + pending
        for frame in frames {
            frame.releaseBuffer()
        }
        return frames.count
    }

    @discardableResult
    func clearQueuedFramesForFreshnessCatchUp() -> Int {
        let queued = queuedFrames.drain()
        let pending = Array(pendingOrderedFrames.values)
        pendingOrderedFrames.removeAll(keepingCapacity: false)
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        guard !queued.isEmpty || !pending.isEmpty else { return 0 }
        let frames = queued + pending
        for frame in frames {
            frame.releaseBuffer()
        }
        recordQueueDrops(frames.count)
        return frames.count
    }

    func shouldDeferSharedClipboardApply() -> Bool {
        clientRecoveryStatus != .idle || reassembler.isAwaitingKeyframe()
    }

    @discardableResult
    func handleMemoryPressure(resetDecoder: Bool = false) async -> Bool {
        let queuedFramesTrimmed = clearQueuedFramesForRecovery()
        let reassemblerTrim = reassembler.trimForMemoryPressure()
        let renderFramesTrimmed = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
        if resetDecoder {
            await decoder.resetForNewSession()
        } else {
            await decoder.flushMemoryPool()
        }

        let didTrim = queuedFramesTrimmed > 0 ||
            reassemblerTrim.evictedFrames > 0 ||
            reassemblerTrim.purgedRetainedBytes > 0 ||
            renderFramesTrimmed > 0 ||
            resetDecoder
        guard didTrim else { return false }

        MirageLogger.client(
            "Memory pressure trimmed stream \(streamID): queuedFrames=\(queuedFramesTrimmed), " +
                "reassemblerFrames=\(reassemblerTrim.evictedFrames), renderFrames=\(renderFramesTrimmed), " +
                "reassemblerBytes=\(reassemblerTrim.releasedPendingBytes), " +
                "purgedRetainedBytes=\(reassemblerTrim.purgedRetainedBytes), resetDecoder=\(resetDecoder)"
        )

        if isRunning, !isStopping {
            await requestKeyframeRecovery(reason: .manualRecovery)
        }

        return true
    }

    private func logQueueDropIfNeeded() {
        let now = currentTime()
        if now - lastQueueDropLogTime >= Self.queueDropLogInterval {
            lastQueueDropLogTime = now
            let dropped = queueDropsSinceLastLog
            queueDropsSinceLastLog = 0
            MirageLogger.client(
                "Decode backpressure: dropped \(dropped) frames (depth \(queuedFrames.count)) for stream \(streamID)"
            )
        }
    }

    /// Stop the controller and clean up resources
    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        isRunning = false

        // Stop frame processing - finish stream and cancel task
        stopFrameProcessingPipeline()
        stopMetricsReporting()
        stopMediaFeedbackReporting()
        stopFreezeMonitor()
        stopFirstPresentedFrameMonitor()
        onKeyframeNeeded = nil
        onResizeEvent = nil
        onResizeStateChanged = nil
        onFrameDecoded = nil
        onMediaFeedback = nil
        onFirstFrameDecoded = nil
        onPostResizeFrameDecoded = nil
        onFirstFramePresented = nil
        onStallEvent = nil
        onRecoveryStatusChanged = nil
        onTerminalStartupFailure = nil
        onTerminalLiveRecoveryFailure = nil

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        cancelMemoryBudgetRecoveryTask()
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        recoveryCoordinator.reset()
        realtimeMediaSession = RealtimeMediaSession(streamID: streamID, targetFrameRate: decodeSchedulerTargetFPS)
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
        liveRecoveryHardRecoveryTimestamps.removeAll(keepingCapacity: false)
        hasTriggeredTerminalLiveRecoveryFailure = false
        resetRecoveryStabilizationTracking()
        latestHostMetricsMessage = nil
        latestHostCadencePressureSample = nil
        latestRenderTelemetrySnapshot = nil
        lastStreamingAnomalyDiagnosticSignature = nil
        lastStreamingAnomalyDiagnosticTime = 0
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        tierPromotionProbeTask?.cancel()
        tierPromotionProbeTask = nil
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        MirageRenderStreamStore.shared.clear(for: streamID)
        await decoder.setErrorThresholdHandler {}
        await decoder.setDimensionChangeHandler {}
        await decoder.stopDecoding()
        await GlobalDecodeBudgetController.shared.unregister(streamID: streamID)
    }

    private func startMetricsReporting() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.metricsDispatchInterval)
                } catch {
                    break
                }
                await dispatchMetrics()
            }
        }
    }

    func stopMetricsReporting() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func startMediaFeedbackReporting() {
        mediaFeedbackTask?.cancel()
        mediaFeedbackSequence = 0
        mediaFeedbackTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.mediaFeedbackDispatchInterval)
                } catch {
                    break
                }
                await dispatchMediaFeedback()
            }
        }
    }

    func stopMediaFeedbackReporting() {
        mediaFeedbackTask?.cancel()
        mediaFeedbackTask = nil
        mediaFeedbackSequence = 0
    }

    func setMediaFeedbackSuspended(_ suspended: Bool) {
        guard mediaFeedbackSuspended != suspended else { return }
        mediaFeedbackSuspended = suspended
        if suspended {
            MirageLogger.client("Suspended receiver media feedback for stream \(streamID)")
        } else {
            MirageLogger.client("Resumed receiver media feedback for stream \(streamID)")
        }
    }

    private func dispatchMediaFeedback() async {
        guard isRunning, !isStopping, !mediaFeedbackSuspended else { return }
        let now = currentTime()
        let frameSnapshot = metricsTracker.snapshot(now: now)
        let reassemblerMetrics = reassembler.snapshotMetrics()
        let renderTelemetry = MirageRenderStreamStore.shared.feedbackTelemetrySnapshot(for: streamID)
        mediaFeedbackSequence &+= 1

        let decodeBacklogFrames = queuedFrames.count + pendingOrderedFrames.count
        let presentationBacklogFrames = renderTelemetry.pendingFrameCount
        let queueEstimateFrames = reassemblerMetrics.pendingFrameCount +
            decodeBacklogFrames +
            presentationBacklogFrames
        let ackRanges: [MediaFeedbackFrameRange] = reassemblerMetrics.framesDelivered > 0
            ? [MediaFeedbackFrameRange(
                startFrame: reassemblerMetrics.lastCompletedFrame,
                endFrame: reassemblerMetrics.lastCompletedFrame
            )]
            : []
        let sourceTargetFPS = max(1, streamCadenceTarget.sourceFPS)
        let feedback = ReceiverMediaFeedbackMessage(
            streamID: streamID,
            sequence: mediaFeedbackSequence,
            sentAtUptime: now,
            targetFPS: sourceTargetFPS,
            ackRanges: ackRanges,
            lostFrameCount: reassemblerMetrics.droppedFrames + frameSnapshot.queueDroppedFrames,
            discardedPacketCount: reassemblerMetrics.discardedPackets,
            jitterP95Ms: frameSnapshot.receivedFrameIntervalP95Ms,
            jitterP99Ms: frameSnapshot.receivedFrameIntervalP99Ms,
            queueEstimateFrames: queueEstimateFrames,
            reassemblyBacklogFrames: reassemblerMetrics.pendingFrameCount,
            reassemblyBacklogKeyframes: reassemblerMetrics.pendingKeyframeCount,
            reassemblyBacklogBytes: reassemblerMetrics.pendingFrameBytes,
            decodeBacklogFrames: decodeBacklogFrames,
            presentationBacklogFrames: presentationBacklogFrames,
            decodedFPS: frameSnapshot.decodedFPS,
            receivedFPS: frameSnapshot.receivedFPS,
            rendererAcceptedFPS: renderTelemetry.layerEnqueueFPS,
            rendererPresentedFPS: renderTelemetry.visibleFrameCadenceKnown
                ? renderTelemetry.visibleFrameFPS
                : 0,
            recoveryState: Self.mediaFeedbackRecoveryState(for: clientRecoveryStatus)
        )
        realtimeMediaSession.recordFeedback(feedback)
        let callback = onMediaFeedback
        callback?(feedback)
    }

    private func dispatchMetrics() async {
        let now = currentTime()
        let presentationProgressed = syncPresentationProgressFromFrameStore(now: now)
        if presentationProgressed, hasPresentedFirstFrame {
            await clearTransientRecoveryStateAfterPresentationProgress()
        }
        let snapshot = metricsTracker.snapshot(now: now)
        let reassemblerMetrics = reassembler.snapshotMetrics()
        let droppedFrames = reassemblerMetrics.droppedFrames + snapshot.queueDroppedFrames
        let renderTelemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        let renderDiagnostics = MirageRenderStreamStore.shared.diagnosticsSnapshot(for: streamID)
        let decodeBacklogFrames = queuedFrames.count + pendingOrderedFrames.count
        let decodeSubmissionInFlightCount = await decoder.currentInFlightDecodeSubmissions()
        latestRenderTelemetrySnapshot = renderTelemetry
        evaluateAdaptiveJitterHold(receivedFPS: snapshot.receivedFPS)
        await evaluateDecodeSubmissionLimit(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS
        )
        let metrics = ClientFrameMetrics(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            decodedWorstGapMs: snapshot.decodedWorstGapMs,
            decodedFrameIntervalP95Ms: snapshot.decodedFrameIntervalP95Ms,
            decodedFrameIntervalP99Ms: snapshot.decodedFrameIntervalP99Ms,
            receivedWorstGapMs: snapshot.receivedWorstGapMs,
            receivedFrameIntervalP95Ms: snapshot.receivedFrameIntervalP95Ms,
            receivedFrameIntervalP99Ms: snapshot.receivedFrameIntervalP99Ms,
            droppedFrames: droppedFrames,
            renderStoreEnqueueFPS: renderTelemetry.renderStoreEnqueueFPS,
            displayLinkCallbackFPS: renderTelemetry.displayLinkCallbackFPS,
            displayTickWorkerFPS: renderTelemetry.displayTickWorkerFPS,
            displayTickMainRelayFPS: renderTelemetry.displayTickMainRelayFPS,
            displayTickFPS: renderTelemetry.displayTickFPS,
            presentationPassFPS: renderTelemetry.presentationPassFPS,
            presentationEligibleFPS: renderTelemetry.presentationEligibleFPS,
            submitAttemptFPS: renderTelemetry.submitAttemptFPS,
            layerEnqueueFPS: renderTelemetry.layerEnqueueFPS,
            uniqueLayerEnqueueFPS: renderTelemetry.uniqueLayerEnqueueFPS,
            visibleFrameFPS: renderTelemetry.visibleFrameFPS,
            visibleFrameCadenceKnown: renderTelemetry.visibleFrameCadenceKnown,
            visiblePresentationStallCount: renderTelemetry.visiblePresentationStallCount,
            visibleWorstPresentationGapMs: renderTelemetry.visibleWorstPresentationGapMs,
            visibleFrameIntervalP95Ms: renderTelemetry.visibleFrameIntervalP95Ms,
            visibleFrameIntervalP99Ms: renderTelemetry.visibleFrameIntervalP99Ms,
            visibleFrameIntervalMaxMs: renderTelemetry.visibleFrameIntervalMaxMs,
            repeatedSourceFrameCount: renderTelemetry.repeatedSourceFrameCount,
            framesSubmittedPerPassAverage: renderTelemetry.framesSubmittedPerPassAverage,
            framesSubmittedPerPassMax: renderTelemetry.framesSubmittedPerPassMax,
            pendingFrameCount: renderTelemetry.pendingFrameCount,
            unsubmittedPendingFrameCount: renderTelemetry.unsubmittedPendingFrameCount,
            retainedSubmittedFrameCount: renderTelemetry.retainedSubmittedFrameCount,
            pendingFrameAgeMs: renderTelemetry.pendingFrameAgeMs,
            oldestUnsubmittedAgeMs: renderTelemetry.oldestUnsubmittedAgeMs,
            newestUnsubmittedAgeMs: renderTelemetry.newestUnsubmittedAgeMs,
            overwrittenPendingFrames: renderTelemetry.overwrittenPendingFrames,
            renderStoreOverwriteFPS: renderTelemetry.renderStoreOverwriteFPS,
            lowestLatencyFreshBacklogDrops: renderTelemetry.lowestLatencyFreshBacklogDrops,
            lateFrameDrops: renderTelemetry.lateFrameDrops,
            coalescedBeforeSubmitCount: renderTelemetry.coalescedBeforeSubmitCount,
            duplicateRemoteTimestampCount: renderTelemetry.duplicateRemoteTimestampCount,
            correctedStreamTimestampCount: renderTelemetry.correctedStreamTimestampCount,
            displayLayerNotReadyCount: renderTelemetry.displayLayerNotReadyCount,
            sampleBufferRendererNotReadyCount: renderTelemetry.sampleBufferRendererNotReadyCount,
            displayImmediatelySubmittedCount: renderTelemetry.displayImmediatelySubmittedCount,
            rendererReadyDrainPassCount: renderTelemetry.rendererReadyDrainPassCount,
            rendererReadyDrainSubmittedCount: renderTelemetry.rendererReadyDrainSubmittedCount,
            rendererReadyRearmCount: renderTelemetry.rendererReadyRearmCount,
            repeatedFrameCount: renderTelemetry.repeatedFrameCount,
            displayTickNoFrameCount: renderTelemetry.displayTickNoFrameCount,
            tickNoEligibleFrameCount: renderTelemetry.tickNoEligibleFrameCount,
            frameArrivedAfterNoFrameTickCount: renderTelemetry.frameArrivedAfterNoFrameTickCount,
            frameArrivalFallbackCount: renderTelemetry.frameArrivalFallbackCount,
            frameArrivalFallbackScheduledCount: renderTelemetry.frameArrivalFallbackScheduledCount,
            frameArrivalFallbackSubmittedCount: renderTelemetry.frameArrivalFallbackSubmittedCount,
            noFrameTickToFrameArrivalMaxMs: renderTelemetry.noFrameTickToFrameArrivalMaxMs,
            missedVSyncCount: renderTelemetry.missedVSyncCount,
            smoothestOneFrameHoldCount: renderTelemetry.smoothestOneFrameHoldCount,
            displayCadenceBelowSourceCount: renderTelemetry.displayCadenceBelowSourceCount,
            displayTickIntervalP95Ms: renderTelemetry.displayTickIntervalP95Ms,
            displayTickIntervalP99Ms: renderTelemetry.displayTickIntervalP99Ms,
            playoutDelayFrames: renderTelemetry.playoutDelayFrames,
            presentationStallCount: renderTelemetry.presentationStallCount,
            worstPresentationGapMs: renderTelemetry.worstPresentationGapMs,
            frameIntervalP95Ms: renderTelemetry.frameIntervalP95Ms,
            frameIntervalP99Ms: renderTelemetry.frameIntervalP99Ms,
            frameIntervalMaxMs: renderTelemetry.frameIntervalMaxMs,
            displayTickIntervalMaxMs: renderTelemetry.displayTickIntervalMaxMs,
            displayTickMainDelayMaxMs: renderTelemetry.displayTickMainDelayMaxMs,
            renderWorkerSubmitDelayMaxMs: renderTelemetry.renderWorkerSubmitDelayMaxMs,
            renderStoreClearCount: renderDiagnostics.clearCount,
            renderGenerationBumpCount: renderDiagnostics.generationBumpCount,
            renderMemoryTrimClearCount: renderDiagnostics.memoryTrimClearCount,
            presenterTimingResetCount: renderDiagnostics.presenterTimingResetCount,
            displayLayerLivenessResetCount: renderDiagnostics.displayLayerLivenessResetCount,
            presentationRecoveryRequestCount: renderDiagnostics.presentationRecoveryRequestCount,
            presentationRecoveryHandlerDispatchCount: renderDiagnostics.presentationRecoveryHandlerDispatchCount,
            lastRenderGenerationBumpReason: renderDiagnostics.lastGenerationBumpReason,
            lastPresentationRecoveryOutcome: renderDiagnostics.lastPresentationRecoveryOutcome,
            decodeHealthy: renderTelemetry.decodeHealthy,
            activeJitterHoldMs: adaptiveJitterHoldMs,
            decodeBacklogFrames: decodeBacklogFrames,
            decodeSubmissionInFlightCount: decodeSubmissionInFlightCount,
            decodeSubmissionLimit: currentDecodeSubmissionLimit,
            reassemblerPendingFrameCount: reassemblerMetrics.pendingFrameCount,
            reassemblerPendingKeyframeCount: reassemblerMetrics.pendingKeyframeCount,
            reassemblerPendingBytes: reassemblerMetrics.pendingFrameBytes,
            frameBufferPoolRetainedBytes: reassemblerMetrics.frameBufferPoolRetainedBytes,
            reassemblerBudgetEvictions: reassemblerMetrics.budgetEvictions,
            decoderOutputPixelFormat: await decoder.decodedOutputPixelFormatName(),
            usingHardwareDecoder: await decoder.currentHardwareDecoderStatus()
        )
        let callback = onFrameDecoded
        await MainActor.run {
            callback?(metrics)
        }
    }

    func evaluateDecodeSubmissionLimit(decodedFPS: Double, receivedFPS: Double) async {
        if presentationTier == .passiveSnapshot {
            decodeSubmissionStressStreak = 0
            decodeSubmissionHealthyStreak = 0
            decodeSubmissionBaselineLimit = 1
            decodeSchedulerTargetFPS = max(1, decodeSchedulerTargetFPS)
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
            if currentDecodeSubmissionLimit != 1 {
                currentDecodeSubmissionLimit = 1
                await decoder.setDecodeSubmissionLimit(limit: 1, reason: "passive tier fixed submission")
            }
            return
        }

        let targetFPS = max(1, decodeSchedulerTargetFPS)
        let ratio = decodedFPS / Double(targetFPS)
        let maximumLimit = VideoDecoder.maximumDecodeSubmissionLimit(
            targetFrameRate: targetFPS,
            latencyMode: streamCadenceTarget.latencyMode
        )
        if currentDecodeSubmissionLimit > maximumLimit {
            currentDecodeSubmissionLimit = maximumLimit
            await decoder.setDecodeSubmissionLimit(
                limit: maximumLimit,
                reason: "decode submission cap"
            )
        }
        let stressLimit = min(maximumLimit, decodeSubmissionBaselineLimit + 1)
        let decodeGap = max(0.0, receivedFPS - decodedFPS)
        let sourceBound = receivedFPS > 0 && decodeGap <= Self.decodeSubmissionSourceBoundGapFPS
        let decodeBound = receivedFPS > 0 && decodeGap >= Self.decodeSubmissionDecodeBoundGapFPS
        let hostCadencePressure = hostCadencePressureDiagnostic(sample: latestHostCadencePressureSample)

        if ratio < Self.decodeSubmissionStressThreshold {
            if decodeBound {
                if lastDecodeSubmissionConstraintWasSourceBound != false {
                    await maybeLogStreamingAnomalyDiagnostic(
                        trigger: "decode-submission",
                        decodedFPS: decodedFPS,
                        receivedFPS: receivedFPS
                    )
                }
                lastDecodeSubmissionConstraintWasSourceBound = false
                lastSourceBoundDiagnosticSignature = nil
                decodeSubmissionStressStreak += 1
                decodeSubmissionHealthyStreak = 0
            } else {
                let sourceDiagnosticSignature = hostCadencePressure?.kind.rawValue ?? "generic-source-bound"
                if sourceBound,
                   lastDecodeSubmissionConstraintWasSourceBound != true ||
                   lastSourceBoundDiagnosticSignature != sourceDiagnosticSignature {
                    await maybeLogStreamingAnomalyDiagnostic(
                        trigger: "decode-submission",
                        decodedFPS: decodedFPS,
                        receivedFPS: receivedFPS
                    )
                    lastDecodeSubmissionConstraintWasSourceBound = true
                    lastSourceBoundDiagnosticSignature = sourceDiagnosticSignature
                } else if !sourceBound {
                    lastDecodeSubmissionConstraintWasSourceBound = nil
                    lastSourceBoundDiagnosticSignature = nil
                }
                decodeSubmissionStressStreak = 0
                decodeSubmissionHealthyStreak = 0
            }
        } else if ratio >= Self.decodeSubmissionHealthyThreshold {
            decodeSubmissionHealthyStreak += 1
            decodeSubmissionStressStreak = 0
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
        } else {
            decodeSubmissionStressStreak = 0
            decodeSubmissionHealthyStreak = 0
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
        }

        if currentDecodeSubmissionLimit < stressLimit,
           decodeSubmissionStressStreak >= Self.decodeSubmissionStressWindows {
            decodeSubmissionStressStreak = 0
            currentDecodeSubmissionLimit = stressLimit
            await decoder.setDecodeSubmissionLimit(
                limit: stressLimit,
                reason: "decode stress (decode-bound)"
            )
            return
        }

        if currentDecodeSubmissionLimit > decodeSubmissionBaselineLimit,
           decodeSubmissionHealthyStreak >= Self.decodeSubmissionHealthyWindows {
            decodeSubmissionHealthyStreak = 0
            currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
            await decoder.setDecodeSubmissionLimit(
                limit: decodeSubmissionBaselineLimit,
                reason: "decode recovered"
            )
        }
    }
}
