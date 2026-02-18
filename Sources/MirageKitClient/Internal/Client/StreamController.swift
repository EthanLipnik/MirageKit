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

/// Controls the lifecycle and state of a single stream.
/// Owned by MirageClientService, not by views. This ensures:
/// - Decoder lifecycle is independent of SwiftUI lifecycle
/// - Resize state machine can be tested without SwiftUI
/// - Frame distribution is not blocked by MainActor
actor StreamController {
    // MARK: - Types

    enum RecoveryReason: Sendable {
        case decodeErrorThreshold
        case frameLoss
        case freezeTimeout
        case keyframeRecoveryLoop
        case manualRecovery

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
            }
        }
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
        let presentationTime: CMTime
        let isKeyframe: Bool
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    struct ClientFrameMetrics: Sendable {
        let decodedFPS: Double
        let receivedFPS: Double
        let droppedFrames: UInt64
        let presentedFPS: Double
        let uniquePresentedFPS: Double
        let renderBufferDepth: Int
        let decodeHealthy: Bool
    }

    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID

    /// HEVC decoder for this stream
    let decoder: HEVCDecoder

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

    /// Interval for retrying keyframe requests while decoder is unhealthy
    static let keyframeRecoveryInterval: Duration = .seconds(1)
    /// Minimum spacing for repeated keyframe retries once keyframe-only mode is active.
    static let keyframeRecoveryRetryInterval: CFAbsoluteTime = 0.5
    /// Escalate decode-threshold recovery to a full reset only after repeated failures.
    static let decodeRecoveryEscalationWindow: CFAbsoluteTime = 8.0
    static let decodeRecoveryEscalationThreshold: Int = 3

    /// Duration without decoded frame presentation progress before recovery is requested.
    static let freezeTimeout: CFAbsoluteTime = 5.0

    /// Interval for checking freeze state.
    static let freezeCheckInterval: Duration = .milliseconds(500)
    static let freezeRecoveryCooldown: CFAbsoluteTime = 3.0
    static let freezeRecoveryEscalationThreshold: Int = 2

    /// Maximum number of compressed frames buffered ahead of decode.
    static let maxQueuedFrames: Int = 48

    /// Minimum interval between decode backpressure drop logs.
    static let queueDropLogInterval: CFAbsoluteTime = 1.0
    static let backpressureLogCooldown: CFAbsoluteTime = 1.0
    static let overloadWindow: CFAbsoluteTime = 8.0
    static let overloadQueueDropThreshold: Int = 12
    static let overloadRecoveryThreshold: Int = 2
    static let decodeStormThreshold: Int = 2
    static let adaptiveFallbackCooldown: CFAbsoluteTime = 15.0
    static let recoveryRequestDispatchCooldown: CFAbsoluteTime = 0.5
    static let decodeSubmissionMaximumLimit: Int = 3
    static let decodeSubmissionStressThreshold: Double = 0.80
    static let decodeSubmissionHealthyThreshold: Double = 0.95
    static let decodeSubmissionStressWindows: Int = 2
    static let decodeSubmissionHealthyWindows: Int = 3

    /// Pending resize debounce task
    var resizeDebounceTask: Task<Void, Never>?

    /// Task that periodically requests keyframes during decoder recovery
    var keyframeRecoveryTask: Task<Void, Never>?
    var lastRecoveryRequestTime: CFAbsoluteTime = 0

    /// Whether we've received at least one frame
    var hasReceivedFirstFrame = false

    /// Bounded queue of frames waiting to be decoded.
    var queuedFrames = MirageRingBuffer<FrameData>(minimumCapacity: 32)

    /// Continuation resumed when the decode task is waiting for a frame.
    var dequeueContinuation: CheckedContinuation<FrameData?, Never>?

    /// Task that processes frames from the stream in FIFO order
    /// This ensures frames are decoded sequentially, preventing P-frame decode errors
    var frameProcessingTask: Task<Void, Never>?

    var queueDropsSinceLastLog: UInt64 = 0
    var lastQueueDropLogTime: CFAbsoluteTime = 0
    var queueDropTimestamps: [CFAbsoluteTime] = []
    var recoveryRequestTimestamps: [CFAbsoluteTime] = []
    var decodeThresholdTimestamps: [CFAbsoluteTime] = []
    var decodeRecoveryEscalationTimestamps: [CFAbsoluteTime] = []
    var lastRecoveryRequestDispatchTime: CFAbsoluteTime = 0
    var lastBackpressureLogTime: CFAbsoluteTime = 0
    var lastAdaptiveFallbackSignalTime: CFAbsoluteTime = 0
    var decodeSchedulerTargetFPS: Int = 60
    var decodeSubmissionBaselineLimit: Int = 2
    var decodeSubmissionStressStreak: Int = 0
    var decodeSubmissionHealthyStreak: Int = 0
    var currentDecodeSubmissionLimit: Int = 2

    let metricsTracker = ClientFrameMetricsTracker()
    var metricsTask: Task<Void, Never>?
    var lastMetricsLogTime: CFAbsoluteTime = 0
    static let metricsDispatchInterval: Duration = .milliseconds(500)

    var lastDecodedFrameTime: CFAbsoluteTime = 0
    var lastPresentedSequenceObserved: UInt64 = 0
    var lastPresentedProgressTime: CFAbsoluteTime = 0
    var lastFreezeRecoveryTime: CFAbsoluteTime = 0
    var consecutiveFreezeRecoveries: Int = 0
    var freezeMonitorTask: Task<Void, Never>?
    private let nowProvider: @Sendable () -> CFAbsoluteTime

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
    /// The delegate should read from MirageFrameCache if it needs the actual frame.
    private(set) var onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)?

    /// Called when the first frame is decoded for a stream.
    private(set) var onFirstFrame: (@MainActor @Sendable () -> Void)?

    /// Called when sustained decode overload should trigger host fallback.
    private(set) var onAdaptiveFallbackNeeded: (@MainActor @Sendable () -> Void)?

    /// Set callbacks for stream events
    func setCallbacks(
        onKeyframeNeeded: (@MainActor @Sendable () -> Void)?,
        onResizeEvent: (@MainActor @Sendable (ResizeEvent) -> Void)?,
        onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)? = nil,
        onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil,
        onFirstFrame: (@MainActor @Sendable () -> Void)? = nil,
        onAdaptiveFallbackNeeded: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeEvent = onResizeEvent
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
        self.onFirstFrame = onFirstFrame
        self.onAdaptiveFallbackNeeded = onAdaptiveFallbackNeeded
    }

    // MARK: - Initialization

    /// Create a new stream controller
    init(
        streamID: StreamID,
        maxPayloadSize: Int,
        nowProvider: @escaping @Sendable () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        self.streamID = streamID
        decoder = HEVCDecoder()
        reassembler = FrameReassembler(streamID: streamID, maxPayloadSize: maxPayloadSize)
        self.nowProvider = nowProvider
    }

    func currentTime() -> CFAbsoluteTime {
        nowProvider()
    }

    /// Start the controller - sets up decoder and reassembler callbacks
    func start() async {
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        lastRecoveryRequestDispatchTime = 0
        stopFreezeMonitor()
        let presentationSnapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)
        lastPresentedSequenceObserved = presentationSnapshot.sequence
        lastPresentedProgressTime = presentationSnapshot.presentedTime

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
            // Also store in global cache for iOS gesture tracking compatibility
            let decodeTime = CFAbsoluteTimeGetCurrent()
            MirageFrameCache.shared.store(
                pixelBuffer,
                contentRect: contentRect,
                decodeTime: decodeTime,
                presentationTime: presentationTime,
                metalTexture: nil,
                texture: nil,
                for: capturedStreamID
            )

            if metricsTracker.recordDecodedFrame() {
                Task { [weak self] in
                    await self?.markFirstFrameReceived()
                }
            }
            Task { [weak self] in
                await self?.recordDecodedFrame()
            }
        }

        await startFrameProcessingPipeline()
        startMetricsReporting()
    }

    func startFrameProcessingPipeline() async {
        finishFrameQueue()
        queueDropsSinceLastLog = 0
        lastQueueDropLogTime = 0
        decodeThresholdTimestamps.removeAll(keepingCapacity: false)
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
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

        // Start the frame processing task - single task processes all frames sequentially
        let capturedDecoder = decoder
        frameProcessingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let frame = await dequeueFrame() else { break }
                defer { frame.releaseBuffer() }
                do {
                    try await capturedDecoder.decodeFrame(
                        frame.data,
                        presentationTime: frame.presentationTime,
                        isKeyframe: frame.isKeyframe,
                        contentRect: frame.contentRect
                    )
                } catch {
                    MirageLogger.error(.client, "Decode error: \(error)")
                }
            }
        }

        // Set up reassembler callback - enqueue frames for ordered processing
        let metricsTracker = metricsTracker
        let recordReceivedFrame: @Sendable () -> Void = {
            metricsTracker.recordReceivedFrame()
        }
        let reassemblerHandler: @Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void)
            -> Void = { [weak self] _, frameData, isKeyframe, timestamp, contentRect, releaseBuffer in
                let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
                recordReceivedFrame()

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
                    await self.enqueueFrame(frame)
                }
            }
        reassembler.setFrameHandler(reassemblerHandler)
        reassembler.setFrameLossHandler { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleFrameLossSignal()
            }
        }
    }

    func stopFrameProcessingPipeline() {
        finishFrameQueue()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
    }

    private func enqueueFrame(_ frame: FrameData) async {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: frame)
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
        if !queuedFrames.isEmpty {
            return queuedFrames.popFirst()
        }
        return await withCheckedContinuation { continuation in
            dequeueContinuation = continuation
        }
    }

    private func finishFrameQueue() {
        if let continuation = dequeueContinuation {
            dequeueContinuation = nil
            continuation.resume(returning: nil)
        }
        if queuedFrames.isEmpty { return }
        let frames = queuedFrames.drain()
        for frame in frames {
            frame.releaseBuffer()
        }
    }

    func clearQueuedFramesForRecovery() {
        guard !queuedFrames.isEmpty else { return }
        let frames = queuedFrames.drain()
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
        // Stop frame processing - finish stream and cancel task
        stopFrameProcessingPipeline()
        stopMetricsReporting()
        stopFreezeMonitor()

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        MirageFrameCache.shared.clear(for: streamID)
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

    private func stopMetricsReporting() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func dispatchMetrics() async {
        let now = currentTime()
        let snapshot = metricsTracker.snapshot(now: now)
        let droppedFrames = reassembler.getDroppedFrameCount() + snapshot.queueDroppedFrames
        let renderTelemetry = MirageFrameCache.shared.renderTelemetrySnapshot(for: streamID)
        await evaluateDecodeSubmissionLimit(decodedFPS: snapshot.decodedFPS)
        logMetricsIfNeeded(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            droppedFrames: droppedFrames
        )
        let metrics = ClientFrameMetrics(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            droppedFrames: droppedFrames,
            presentedFPS: renderTelemetry.presentedFPS,
            uniquePresentedFPS: renderTelemetry.uniquePresentedFPS,
            renderBufferDepth: renderTelemetry.queueDepth,
            decodeHealthy: renderTelemetry.decodeHealthy
        )
        let callback = onFrameDecoded
        await MainActor.run {
            callback?(metrics)
        }
    }

    func evaluateDecodeSubmissionLimit(decodedFPS: Double) async {
        let targetFPS = max(1, decodeSchedulerTargetFPS)
        let ratio = decodedFPS / Double(targetFPS)
        let stressLimit = min(Self.decodeSubmissionMaximumLimit, decodeSubmissionBaselineLimit + 1)

        if ratio < Self.decodeSubmissionStressThreshold {
            decodeSubmissionStressStreak += 1
            decodeSubmissionHealthyStreak = 0
        } else if ratio >= Self.decodeSubmissionHealthyThreshold {
            decodeSubmissionHealthyStreak += 1
            decodeSubmissionStressStreak = 0
        } else {
            decodeSubmissionStressStreak = 0
            decodeSubmissionHealthyStreak = 0
        }

        if currentDecodeSubmissionLimit < stressLimit,
           decodeSubmissionStressStreak >= Self.decodeSubmissionStressWindows {
            decodeSubmissionStressStreak = 0
            currentDecodeSubmissionLimit = stressLimit
            await decoder.setDecodeSubmissionLimit(limit: stressLimit, reason: "decode stress")
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
