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

private final class FrameEnqueueOrderAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrder: UInt64 = 0

    func allocate() -> UInt64 {
        lock.lock()
        let order = nextOrder
        nextOrder &+= 1
        lock.unlock()
        return order
    }

    func reset() {
        lock.lock()
        nextOrder = 0
        lock.unlock()
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

    struct TerminalStartupFailure: Sendable, Equatable {
        let reason: RecoveryReason
        let hardRecoveryAttempts: Int
        let waitReason: String?

        var errorMessage: String {
            "Stream failed to present its first frame after bounded recovery."
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

    enum PostResizeDecodeAdmissionDecision: Equatable, Sendable {
        case accept
        case dropNonKeyframeWhileAwaitingFirstFrame
    }

    nonisolated static func postResizeDecodeAdmissionDecision(
        awaitingFirstFrameAfterResize: Bool,
        isKeyframe: Bool
    )
    -> PostResizeDecodeAdmissionDecision {
        if awaitingFirstFrameAfterResize, !isKeyframe {
            return .dropNonKeyframeWhileAwaitingFirstFrame
        }
        return .accept
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
        let presentationTime: CMTime
        let isKeyframe: Bool
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    struct ClientFrameMetrics: Sendable {
        let decodedFPS: Double
        let receivedFPS: Double
        let droppedFrames: UInt64
        let submittedFPS: Double
        let uniqueSubmittedFPS: Double
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let overwrittenPendingFrames: UInt64
        let displayLayerNotReadyCount: UInt64
        let decodeHealthy: Bool
        let activeJitterHoldMs: Int
        let decoderOutputPixelFormat: String?
        let usingHardwareDecoder: Bool?
    }

    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID

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

    /// Interval for checking freeze state.
    static let freezeCheckInterval: Duration = .milliseconds(250)
    static let freezeRecoveryCooldown: CFAbsoluteTime = 3.0
    static let freezeRecoveryEscalationThreshold: Int = 2

    /// Maximum number of compressed frames buffered ahead of decode.
    static let maxQueuedFrames: Int = 48
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

    /// Minimum interval between decode backpressure drop logs.
    static let queueDropLogInterval: CFAbsoluteTime = 1.0
    static let backpressureLogCooldown: CFAbsoluteTime = 1.0
    static let overloadWindow: CFAbsoluteTime = 8.0
    static let overloadQueueDropThreshold: Int = 12
    static let overloadRecoveryThreshold: Int = 2
    static let decodeStormThreshold: Int = 2
    static let adaptiveFallbackCooldown: CFAbsoluteTime = 15.0
    static let recoveryRequestDispatchCooldown: CFAbsoluteTime = 0.5
    static let backgroundDecodeErrorLogInterval: CFAbsoluteTime = 2.0
    static let decodeErrorLogInterval: CFAbsoluteTime = 15.0
    static let decodeErrorEscalationThreshold: Int = 3
    static let postResizeDecodeErrorGraceInterval: CFAbsoluteTime = 0.75
    static let decodeSubmissionMaximumLimit: Int = 3
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
    /// One-shot probe that verifies decode/presentation progress after passive->active promotion.
    var tierPromotionProbeTask: Task<Void, Never>?
    var lastRecoveryRequestTime: CFAbsoluteTime = 0

    /// Whether we've decoded at least one frame.
    var hasDecodedFirstFrame = false
    /// Whether we've presented at least one frame.
    var hasPresentedFirstFrame = false
    /// True while the decoder should remain keyframe-only for a post-resize transition.
    var awaitingFirstFrameAfterResize = false
    /// Suppresses immediate post-resize decode-threshold recovery until presentation has a chance to resume.
    var postResizeDecodeErrorGraceDeadline: CFAbsoluteTime = 0
    /// True while UI gating waits for the first newly presented frame.
    var awaitingFirstPresentedFrame = false
    /// Startup watchdog vs recovery watchdog mode for the first-frame awaiter.
    var firstPresentedFrameAwaitMode: FirstPresentedFrameAwaitMode = .startup
    /// Last presented sequence at the moment first-frame presentation waiting was armed.
    var firstPresentedFrameBaselineSequence: UInt64 = 0
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
    /// Number of full hard recoveries consumed while still waiting on the first presented frame.
    var startupHardRecoveryCount: Int = 0
    /// True after the controller has concluded startup recovery cannot succeed.
    var hasTriggeredTerminalStartupFailure = false
    /// Bounded queue of frames waiting to be decoded.
    var queuedFrames = MirageRingBuffer<FrameData>(minimumCapacity: 32)
    /// Frames received from callback tasks before their ordered enqueue slot is ready.
    var pendingOrderedFrames: [UInt64: FrameData] = [:]
    var nextExpectedEnqueueOrder: UInt64 = 0
    private let enqueueOrderAllocator = FrameEnqueueOrderAllocator()
    var framePipelineGeneration: UInt64 = 0

    /// Continuation resumed when the decode task is waiting for a frame.
    var dequeueContinuation: CheckedContinuation<FrameData?, Never>?

    /// Task that processes frames from the stream in FIFO order
    /// This ensures frames are decoded sequentially, preventing P-frame decode errors
    var frameProcessingTask: Task<Void, Never>?
    /// Task that waits for first frame presentation progress before unblocking UI state.
    var firstPresentedFrameTask: Task<Void, Never>?

    var queueDropsSinceLastLog: UInt64 = 0
    var lastQueueDropLogTime: CFAbsoluteTime = 0
    var queueDropTimestamps: [CFAbsoluteTime] = []
    var recoveryRequestTimestamps: [CFAbsoluteTime] = []
    var decodeThresholdTimestamps: [CFAbsoluteTime] = []
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
    var lastAdaptiveFallbackSignalTime: CFAbsoluteTime = 0
    var decodeSchedulerTargetFPS: Int = 60
    var decodeSubmissionBaselineLimit: Int = 2
    var decodeSubmissionStressStreak: Int = 0
    var decodeSubmissionHealthyStreak: Int = 0
    var currentDecodeSubmissionLimit: Int = 2
    var lastDecodeSubmissionConstraintWasSourceBound: Bool?
    var lastSourceBoundDiagnosticSignature: String?
    var latestHostCadencePressureSample: HostCadencePressureDiagnosticSample?
    var presentationTier: StreamPresentationTier = .activeLive
    var isRunning = false
    var isStopping = false

    let metricsTracker = ClientFrameMetricsTracker()
    var metricsTask: Task<Void, Never>?
    var lastMetricsLogTime: CFAbsoluteTime = 0
    static let metricsDispatchInterval: Duration = .milliseconds(500)
    let awdlExperimentEnabled: Bool = ProcessInfo.processInfo.environment["MIRAGE_AWDL_EXPERIMENT"] == "1"
    var awdlTransportActive: Bool = false
    var adaptiveJitterHoldMs: Int = 0
    var adaptiveJitterStressStreak: Int = 0
    var adaptiveJitterStableStreak: Int = 0

    // MetalFX upscaler removed — pixel format compatibility issues
    // and no quality improvement justified the complexity.

    var lastDecodedFrameTime: CFAbsoluteTime = 0
    var lastPresentedSequenceObserved: UInt64 = 0
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

    /// Called when the first frame is decoded for a stream.
    private(set) var onFirstFrameDecoded: (@MainActor @Sendable () -> Void)?
    /// Called when the first frame is presented for a stream.
    private(set) var onFirstFramePresented: (@MainActor @Sendable () -> Void)?

    /// Called when sustained decode overload should trigger host fallback.
    private(set) var onAdaptiveFallbackNeeded: (@MainActor @Sendable () -> Void)?
    /// Called when freeze monitoring records a stall event.
    private(set) var onStallEvent: (@MainActor @Sendable () -> Void)?
    /// Called when client recovery state changes.
    private(set) var onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)?
    /// Called when bounded startup recovery is exhausted before the first frame is presented.
    private(set) var onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)?

    /// Last recovery status delivered to the app layer.
    var clientRecoveryStatus: MirageStreamClientRecoveryStatus = .idle

    /// Set callbacks for stream events
    func setCallbacks(
        onKeyframeNeeded: (@MainActor @Sendable () -> Void)?,
        onResizeEvent: (@MainActor @Sendable (ResizeEvent) -> Void)?,
        onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)? = nil,
        onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil,
        onFirstFrameDecoded: (@MainActor @Sendable () -> Void)? = nil,
        onFirstFramePresented: (@MainActor @Sendable () -> Void)? = nil,
        onAdaptiveFallbackNeeded: (@MainActor @Sendable () -> Void)? = nil,
        onStallEvent: (@MainActor @Sendable () -> Void)? = nil,
        onRecoveryStatusChanged: (@MainActor @Sendable (MirageStreamClientRecoveryStatus) -> Void)? = nil,
        onTerminalStartupFailure: (@MainActor @Sendable (TerminalStartupFailure) -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeEvent = onResizeEvent
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
        self.onFirstFrameDecoded = onFirstFrameDecoded
        self.onFirstFramePresented = onFirstFramePresented
        self.onAdaptiveFallbackNeeded = onAdaptiveFallbackNeeded
        self.onStallEvent = onStallEvent
        self.onRecoveryStatusChanged = onRecoveryStatusChanged
        self.onTerminalStartupFailure = onTerminalStartupFailure
    }

    func setClientRecoveryStatus(_ status: MirageStreamClientRecoveryStatus) async {
        guard clientRecoveryStatus != status else { return }
        clientRecoveryStatus = status
        guard let onRecoveryStatusChanged else { return }
        await MainActor.run {
            onRecoveryStatusChanged(status)
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
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        lastRecoveryRequestDispatchTime = 0
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
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
        }

        // Set up dimension change handler - reset reassembler when dimensions change
        let capturedStreamID = streamID
        await decoder.setDimensionChangeHandler { [weak self] in
            guard let self else { return }
            Task {
                self.reassembler.reset()
                MirageLogger.client("Reassembler reset due to dimension change for stream \(capturedStreamID)")
            }
        }

        // Set up frame handler
        let metricsTracker = metricsTracker
        await decoder.startDecoding { [weak self] (pixelBuffer: CVPixelBuffer, presentationTime: CMTime, contentRect: CGRect) in
            let decodeTime = CFAbsoluteTimeGetCurrent()
            let handledByUpscaler = false
            if !handledByUpscaler {
                _ = MirageRenderStreamStore.shared.enqueue(
                    pixelBuffer: pixelBuffer,
                    contentRect: contentRect,
                    decodeTime: decodeTime,
                    presentationTime: presentationTime,
                    for: capturedStreamID
                )
            }

            let firstDecodedFrame = metricsTracker.recordDecodedFrame()
            Task { [weak self] in
                guard let self else { return }
                if firstDecodedFrame { await self.markFirstFrameDecoded() }
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
    }

    func startFrameProcessingPipeline() async {
        framePipelineGeneration &+= 1
        let activePipelineGeneration = framePipelineGeneration
        finishFrameQueue()
        queueDropsSinceLastLog = 0
        lastQueueDropLogTime = 0
        decodeThresholdTimestamps.removeAll(keepingCapacity: false)
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        metricsTracker.reset()
        lastMetricsLogTime = 0
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
                let lease = await decodeBudgetController.acquire(streamID: self.streamID)
                do {
                    try await capturedDecoder.decodeFrame(
                        frame.data,
                        presentationTime: frame.presentationTime,
                        isKeyframe: frame.isKeyframe,
                        contentRect: frame.contentRect
                    )
                    await recordDecodeSuccessIfNeeded()
                } catch {
                    await recordDecodeFailure(error)
                }
                await decodeBudgetController.release(lease)
            }
        }

        // Set up reassembler callback - enqueue frames for ordered processing
        let metricsTracker = metricsTracker
        let recordReceivedFrame: @Sendable () -> Void = {
            metricsTracker.recordReceivedFrame()
        }
        let enqueueOrderAllocator = enqueueOrderAllocator
        let reassemblerHandler: @Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void)
            -> Void = { [weak self] _, frameData, isKeyframe, timestamp, contentRect, releaseBuffer in
                let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
                recordReceivedFrame()
                let enqueueOrder = enqueueOrderAllocator.allocate()

                let frame = FrameData(
                    data: frameData,
                    presentationTime: presentationTime,
                    isKeyframe: isKeyframe,
                    contentRect: contentRect,
                    releaseBuffer: releaseBuffer
                )

                Task {
                    guard let self else {
                        releaseBuffer()
                        return
                    }
                    await self.enqueueFrame(
                        frame,
                        enqueueOrder: enqueueOrder,
                        pipelineGeneration: activePipelineGeneration
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

    func stopFrameProcessingPipeline() {
        framePipelineGeneration &+= 1
        finishFrameQueue()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
    }

    private func recordDecodeSuccessIfNeeded() {
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
                        "\(logMessage) [suppressed-until-freeze-actionable]"
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

    private func enqueueFrame(
        _ frame: FrameData,
        enqueueOrder: UInt64,
        pipelineGeneration: UInt64
    )
    async {
        guard pipelineGeneration == framePipelineGeneration else {
            frame.releaseBuffer()
            return
        }

        pendingOrderedFrames[enqueueOrder] = frame
        while let nextFrame = pendingOrderedFrames.removeValue(forKey: nextExpectedEnqueueOrder) {
            nextExpectedEnqueueOrder &+= 1
            await enqueueFrameInOrder(nextFrame)
        }
    }

    private func enqueueFrameInOrder(_ frame: FrameData) async {
        if Self.postResizeDecodeAdmissionDecision(
            awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize,
            isKeyframe: frame.isKeyframe
        ) == .dropNonKeyframeWhileAwaitingFirstFrame {
            frame.releaseBuffer()
            return
        }

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

        if queuedFrames.count >= Self.maxQueuedFrames {
            let queueDepth = queuedFrames.count
            if frame.isKeyframe {
                clearQueuedFramesForRecovery()
                queuedFrames.append(frame)
                maybeLogDecodeBackpressure(queueDepth: queueDepth)
                return
            }

            frame.releaseBuffer()
            recordQueueDrop()
            maybeLogDecodeBackpressure(queueDepth: queueDepth)
            logQueueDropIfNeeded()
            return
        }

        queuedFrames.append(frame)
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

    func clearQueuedFramesForRecovery() {
        let queued = queuedFrames.drain()
        let pending = Array(pendingOrderedFrames.values)
        pendingOrderedFrames.removeAll(keepingCapacity: false)
        nextExpectedEnqueueOrder = 0
        enqueueOrderAllocator.reset()
        guard !queued.isEmpty || !pending.isEmpty else { return }
        let frames = queued + pending
        for frame in frames {
            frame.releaseBuffer()
        }
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
        stopFreezeMonitor()
        stopFirstPresentedFrameMonitor()
        onKeyframeNeeded = nil
        onResizeEvent = nil
        onResizeStateChanged = nil
        onFrameDecoded = nil
        onFirstFrameDecoded = nil
        onFirstFramePresented = nil
        onAdaptiveFallbackNeeded = nil
        onStallEvent = nil
        onRecoveryStatusChanged = nil
        onTerminalStartupFailure = nil

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        tierPromotionProbeTask?.cancel()
        tierPromotionProbeTask = nil
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

    private func dispatchMetrics() async {
        let now = currentTime()
        let presentationProgressed = syncPresentationProgressFromFrameStore(now: now)
        if presentationProgressed, hasPresentedFirstFrame {
            await clearTransientRecoveryStateAfterPresentationProgress()
        }
        let snapshot = metricsTracker.snapshot(now: now)
        let droppedFrames = reassembler.getDroppedFrameCount() + snapshot.queueDroppedFrames
        let renderTelemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        evaluateAdaptiveJitterHold(receivedFPS: snapshot.receivedFPS)
        await evaluateDecodeSubmissionLimit(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS
        )
        logMetricsIfNeeded(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            droppedFrames: droppedFrames
        )
        let metrics = ClientFrameMetrics(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            droppedFrames: droppedFrames,
            submittedFPS: renderTelemetry.submittedFPS,
            uniqueSubmittedFPS: renderTelemetry.uniqueSubmittedFPS,
            pendingFrameCount: renderTelemetry.pendingFrameCount,
            pendingFrameAgeMs: renderTelemetry.pendingFrameAgeMs,
            overwrittenPendingFrames: renderTelemetry.overwrittenPendingFrames,
            displayLayerNotReadyCount: renderTelemetry.displayLayerNotReadyCount,
            decodeHealthy: renderTelemetry.decodeHealthy,
            activeJitterHoldMs: adaptiveJitterHoldMs,
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
        let stressLimit = min(Self.decodeSubmissionMaximumLimit, decodeSubmissionBaselineLimit + 1)
        let decodeGap = max(0.0, receivedFPS - decodedFPS)
        let sourceBound = receivedFPS > 0 && decodeGap <= Self.decodeSubmissionSourceBoundGapFPS
        let decodeBound = receivedFPS > 0 && decodeGap >= Self.decodeSubmissionDecodeBoundGapFPS
        let hostCadencePressure = hostCadencePressureDiagnostic(sample: latestHostCadencePressureSample)

        if ratio < Self.decodeSubmissionStressThreshold {
            if decodeBound {
                if lastDecodeSubmissionConstraintWasSourceBound != false {
                    let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
                    let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.client(
                        "Decode submission stress classified as decode-bound (decoded \(decodedText)fps, received \(receivedText)fps, target \(targetFPS)fps)"
                    )
                }
                lastDecodeSubmissionConstraintWasSourceBound = false
                lastSourceBoundDiagnosticSignature = nil
                decodeSubmissionStressStreak += 1
                decodeSubmissionHealthyStreak = 0
            } else {
                let sourceDiagnosticSignature = hostCadencePressure?.signature ?? "generic-source-bound"
                if sourceBound,
                   lastDecodeSubmissionConstraintWasSourceBound != true ||
                   lastSourceBoundDiagnosticSignature != sourceDiagnosticSignature {
                    MirageLogger.client(
                        sourceBoundDecodeSubmissionDiagnosticMessage(
                            decodedFPS: decodedFPS,
                            receivedFPS: receivedFPS,
                            targetFPS: targetFPS,
                            hostCadencePressure: hostCadencePressure
                        )
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
