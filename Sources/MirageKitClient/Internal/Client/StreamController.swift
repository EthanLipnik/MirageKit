//
//  StreamController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import CoreVideo
import Foundation

/// Controls the lifecycle and state of a single stream.
/// Owned by MirageClientService, not by views. This ensures:
/// - Decoder lifecycle is independent of SwiftUI lifecycle
/// - Resize state machine can be tested without SwiftUI
/// - Frame distribution is not blocked by MainActor
actor StreamController {
    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID
    nonisolated let decodeFrameTimingCache = DecodeFrameTimingCache()

    /// HEVC decoder for this stream
    let decoder: VideoDecoder

    /// Frame reassembler for this stream
    let reassembler: FrameReassembler

    /// Current resize state
    var resizeState: ResizeState = .idle

    /// Pending resize debounce task
    var resizeDebounceTask: Task<Void, Never>?

    var recoveryCoordinator = RecoveryCoordinator()
    /// One-shot probe that verifies decode/presentation progress after passive->active promotion.
    var tierPromotionProbeTask: Task<Void, Never>?
    var memoryBudgetRecoveryTask: Task<Void, Never>?

    /// Whether we've decoded at least one frame.
    var hasDecodedFirstFrame = false
    /// Whether we've presented at least one frame.
    var hasPresentedFirstFrame = false
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
    /// Last presented sequence at the moment first-frame presentation waiting was armed.
    var firstPresentedFrameBaselineSequence: UInt64 = 0
    /// Generation-aware presentation baseline captured when first-frame waiting was armed.
    var firstPresentedFrameBaselineSnapshot: SubmissionSnapshot?
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
    /// Bounded queue of frames waiting to be decoded.
    var queuedFrames = MirageRingBuffer<FrameData>(minimumCapacity: 32)
    /// Total compressed bytes retained in `queuedFrames`.
    var queuedFrameBytes = 0
    /// Frames received from callback tasks before their ordered enqueue slot is ready.
    var pendingOrderedFrames: [UInt64: FrameData] = [:]
    var nextExpectedEnqueueOrder: UInt64 = 0
    let enqueueOrderAllocator = FrameEnqueueOrderAllocator()
    var framePipelineGeneration: UInt64 = 0
    /// True after the compressed decode queue has dropped an inter-dependent frame.
    var decodeQueueRequiresKeyframe = false

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
    var recoveryKeyframeDispatchTimes: [CFAbsoluteTime] = []
    var lastSoftRecoveryRequestTime: CFAbsoluteTime = 0
    var lastHardRecoveryStartTime: CFAbsoluteTime = 0
    var lastBackpressureLogTime: CFAbsoluteTime = 0
    var streamCadenceTarget = MirageMedia.MirageStreamCadenceTarget(sourceFPS: 60, displayFPS: 60)
    var streamCadenceClock = MirageStreamCadenceClock(targetFPS: 60)
    var decodeSchedulerTargetFPS: Int = 60
    var decodeSubmissionBaselineLimit: Int = 2
    var decodeSubmissionStressStreak: Int = 0
    var decodeSubmissionHealthyStreak: Int = 0
    var currentDecodeSubmissionLimit: Int = 2
    var lastDecodeSubmissionConstraintWasSourceBound: Bool?
    var lastSourceBoundDiagnosticSignature: String?
    var latestHostMetricsMessage: MirageWire.StreamMetricsMessage?
    var latestHostMetricsTime: CFAbsoluteTime = 0
    var latestHostCadencePressureSample: MirageHostCadencePressureDiagnosticSample?
    var latestRenderTelemetrySnapshot: RenderTelemetrySnapshot?
    var renderCadenceMissStreak: Int = 0
    var lastRenderCadenceMissLogTime: CFAbsoluteTime = 0
    var adaptivePresentationSmoothingActive = false
    var adaptivePresentationSmoothingMissStreak = 0
    var adaptivePresentationSmoothingCleanStreak = 0
    var adaptivePresentationSmoothingLastChangeTime: CFAbsoluteTime = 0
    var lastStreamingAnomalyDiagnosticSignature: String?
    var lastStreamingAnomalyDiagnosticTime: CFAbsoluteTime = 0
    var presentationTier: StreamPresentationTier = .activeLive
    var isRunning = false
    var isStopping = false

    let metricsTracker = ClientFrameMetricsTracker()
    var metricsTask: Task<Void, Never>?
    var awdlTransportActive: Bool = false
    var receiverTransportPathKind: MirageCore.MirageNetworkPathKind = .unknown
    var receiverMediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown

    var lastPresentedSequenceObserved: UInt64 = 0
    var lastPresentedProgressTime: CFAbsoluteTime = 0
    var lastDecodedProgressTime: CFAbsoluteTime = 0
    var lastFreezeRecoveryTime: CFAbsoluteTime = 0
    var consecutiveFreezeRecoveries: Int = 0
    var freezeRecoveryEpisodeID: UInt64 = 0
    var freezeRecoveryEpisode: FreezeRecoveryEpisode?
    var freezeMonitorTask: Task<Void, Never>?
    private let nowProvider: @Sendable () -> CFAbsoluteTime
    let applicationForegroundProvider: @Sendable () async -> Bool

    // MARK: - Callbacks

    /// Called when resize state changes
    var onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)?

    /// Called when a keyframe should be requested from host
    var onKeyframeNeeded: (@MainActor @Sendable () -> Bool)?

    /// Called when a frame is decoded (for delegate notification)
    /// This callback notifies AppState that a frame was decoded for UI state tracking.
    /// Does NOT pass the pixel buffer (CVPixelBuffer isn't Sendable).
    /// The delegate should read from MirageRenderStreamStore if it needs the actual frame.
    var onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)?
    var videoIngressMetricsProvider: (@Sendable (StreamID) -> MirageClientVideoIngressMetricsSnapshot?)?

    /// Called when the first frame is decoded for a stream.
    var onFirstFrameDecoded: (@MainActor @Sendable () -> Void)?
    /// Called when the first frame is presented for a stream.
    var onFirstFramePresented: (@MainActor @Sendable () -> Void)?

    /// Called when freeze monitoring records a typed stall event.
    var onStallEvent: (@MainActor @Sendable (RuntimeWorkloadSafetyStallEvent) -> Void)?
    /// Called when client recovery state changes.
    var onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)?
    /// Called when client recovery state or cause changes.
    var onRecoveryStateChanged: (
        @MainActor @Sendable (MirageStreamClientRecoveryStatus, MirageStreamClientRecoveryCause) -> Void
    )?
    /// Called when bounded startup recovery is exhausted before the first frame is presented.
    var onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)?

    /// Last recovery status delivered to the app layer.
    var clientRecoveryStatus: MirageStreamClientRecoveryStatus = .idle
    /// Last recovery cause delivered to the app layer.
    var clientRecoveryCause: MirageStreamClientRecoveryCause = .none
    var recoveryPresentationResetPerformed = false

    /// Set callbacks for stream events
    func setCallbacks(
        onKeyframeNeeded: (@MainActor @Sendable () -> Bool)?,
        onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)? = nil,
        onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil,
        videoIngressMetricsProvider: (@Sendable (StreamID) -> MirageClientVideoIngressMetricsSnapshot?)? = nil,
        onFirstFrameDecoded: (@MainActor @Sendable () -> Void)? = nil,
        onFirstFramePresented: (@MainActor @Sendable () -> Void)? = nil,
        onStallEvent: (@MainActor @Sendable (RuntimeWorkloadSafetyStallEvent) -> Void)? = nil,
        onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)? = nil,
        onRecoveryStateChanged: (
            @MainActor @Sendable (MirageStreamClientRecoveryStatus, MirageStreamClientRecoveryCause) -> Void
        )? = nil,
        onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
        self.videoIngressMetricsProvider = videoIngressMetricsProvider
        self.onFirstFrameDecoded = onFirstFrameDecoded
        self.onFirstFramePresented = onFirstFramePresented
        self.onStallEvent = onStallEvent
        self.onRecoveryStatusChanged = onRecoveryStatusChanged
        self.onRecoveryStateChanged = onRecoveryStateChanged
        self.onTerminalStartupFailure = onTerminalStartupFailure
    }

    func setClientRecoveryStatus(
        _ status: MirageStreamClientRecoveryStatus,
        cause: MirageStreamClientRecoveryCause = .none
    ) async {
        let resolvedCause: MirageStreamClientRecoveryCause = status == .idle ? .none : cause
        let previousStatus = clientRecoveryStatus
        guard clientRecoveryStatus != status || clientRecoveryCause != resolvedCause else { return }
        clientRecoveryStatus = status
        clientRecoveryCause = resolvedCause
        if status == .idle || previousStatus == .idle {
            recoveryPresentationResetPerformed = false
        }
        let statusHandler = onRecoveryStatusChanged
        let stateHandler = onRecoveryStateChanged
        await MainActor.run {
            statusHandler?(status)
            stateHandler?(status, resolvedCause)
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
        self.nowProvider = nowProvider
        if let applicationForegroundProvider {
            self.applicationForegroundProvider = applicationForegroundProvider
        } else {
            self.applicationForegroundProvider = {
                await StreamController.defaultApplicationForegroundProvider()
            }
        }
    }
}

extension StreamController {
    /// Current monotonic reference time from the controller's injectable clock.
    var currentTime: CFAbsoluteTime {
        nowProvider()
    }

    /// Start the controller - sets up decoder and reassembler callbacks
    func start() async {
        isStopping = false
        isRunning = true
        await GlobalDecodeBudgetController.shared.register(streamID: streamID, tier: presentationTier)
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastDecodedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        freezeRecoveryEpisode = nil
        lastRecoveryRequestDispatchTime = 0
        recoveryKeyframeDispatchTimes.removeAll(keepingCapacity: false)
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        recoveryPresentationResetPerformed = false
        resetStartupRecoveryTracking()
        cancelMemoryBudgetRecoveryTask()
        await setClientRecoveryStatus(.idle)
        stopFreezeMonitor()
        let submissionSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        lastPresentedSequenceObserved = submissionSnapshot.sequence
        lastPresentedProgressTime = submissionSnapshot.submittedTime

        // Set up error recovery - request keyframe when decode errors exceed threshold
        await decoder.setErrorThresholdHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.handleDecodeErrorThresholdSignal()
            }
        } onRecovery: { [weak self] in
            guard let self else { return }
            Task {
                await self.handleDecoderRecoverySignal()
            }
        }

        // Set up dimension change handler - reset reassembler when dimensions change
        let capturedStreamID = streamID
        await decoder.setDimensionChangeHandler { [weak self] frameNumber in
            guard let self else { return }
            Task {
                await self.resetReassemblerForDimensionChange(
                    streamID: capturedStreamID,
                    preservingKeyframeFrameNumber: frameNumber
                )
            }
        }

        // Set up frame handler
        let metricsTrackerSnapshot = metricsTracker
        await decoder.startDecoding { [weak self] (pixelBuffer: CVPixelBuffer, presentationTime: CMTime, contentRect: CGRect) in
            let decodeTime = CFAbsoluteTimeGetCurrent()
            let timingEntry = self?.decodeFrameTimingCache.remove(streamPresentationTime: presentationTime)
            let handledByUpscaler = false
            if !handledByUpscaler {
                let remotePresentationTime = timingEntry?.remotePresentationTime ?? .invalid
                let handledByAppAtlasFanout = MirageAppAtlasRenderFanout.shared.enqueueIfNeeded(
                    pixelBuffer: pixelBuffer,
                    contentRect: contentRect,
                    decodeTime: decodeTime,
                    presentationTime: presentationTime,
                    remotePresentationTime: remotePresentationTime,
                    hostEpoch: timingEntry?.hostEpoch,
                    dimensionToken: timingEntry?.dimensionToken,
                    frameNumber: timingEntry?.frameNumber,
                    queueEpoch: timingEntry?.queueEpoch,
                    for: capturedStreamID
                )
                if !handledByAppAtlasFanout {
                    _ = MirageRenderStreamStore.shared.enqueue(
                        pixelBuffer: pixelBuffer,
                        contentRect: contentRect,
                        decodeTime: decodeTime,
                        presentationTime: presentationTime,
                        remotePresentationTime: remotePresentationTime,
                        generation: timingEntry?.renderGeneration ??
                            MirageRenderStreamStore.shared.currentGeneration(for: capturedStreamID),
                        hostEpoch: timingEntry?.hostEpoch,
                        dimensionToken: timingEntry?.dimensionToken,
                        frameNumber: timingEntry?.frameNumber,
                        queueEpoch: timingEntry?.queueEpoch,
                        timeline: nil,
                        for: capturedStreamID
                    )
                }
            }

            let isFirstFrame = metricsTrackerSnapshot.recordDecodedFrame(now: decodeTime)
            Task { [weak self] in
                guard let self else { return }
                if isFirstFrame { await markFirstFrameDecoded() }
                await recordDecodedFrame()
            }
        }

        await startFrameProcessingPipeline()
        if presentationTier == .activeLive {
            await armFirstPresentedFrameAwaiter(reason: "stream-start")
        } else {
            stopFirstPresentedFrameMonitor()
        }
        startMetricsReporting()
    }
}
