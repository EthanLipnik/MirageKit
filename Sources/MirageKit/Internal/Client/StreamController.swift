//
//  StreamController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import Foundation
import CoreMedia
import CoreVideo
import Metal

/// Controls the lifecycle and state of a single stream.
/// Owned by MirageClientService, not by views. This ensures:
/// - Decoder lifecycle is independent of SwiftUI lifecycle
/// - Resize state machine can be tested without SwiftUI
/// - Frame distribution is not blocked by MainActor
actor StreamController {
    // MARK: - Types

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
    }

    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID

    /// HEVC decoder for this stream
    let decoder: HEVCDecoder

    /// Frame reassembler for this stream
    let reassembler: FrameReassembler

    let textureCache = StreamTextureCache()

    /// Current resize state
    var resizeState: ResizeState = .idle

    /// Last sent resize parameters for deduplication
    var lastSentAspectRatio: CGFloat = 0
    var lastSentRelativeScale: CGFloat = 0
    var lastSentPixelSize: CGSize = .zero

    /// Maximum resolution (5K cap)
    static let maxResolutionWidth: CGFloat = 5120
    static let maxResolutionHeight: CGFloat = 2880

    /// Debounce delay for resize events
    static let resizeDebounceDelay: Duration = .milliseconds(200)

    /// Timeout for resize confirmation
    static let resizeTimeout: Duration = .seconds(2)

    /// Interval for retrying keyframe requests while decoder is unhealthy
    static let keyframeRecoveryInterval: Duration = .seconds(1)

    /// Pending resize debounce task
    var resizeDebounceTask: Task<Void, Never>?

    /// Task that periodically requests keyframes during decoder recovery
    var keyframeRecoveryTask: Task<Void, Never>?
    var lastRecoveryRequestTime: CFAbsoluteTime = 0

    /// Whether we've received at least one frame
    var hasReceivedFirstFrame = false

    /// AsyncStream continuation for ordered frame delivery
    /// Frames are yielded here and processed sequentially by frameProcessingTask
    var frameContinuation: AsyncStream<FrameData>.Continuation?

    /// Task that processes frames from the stream in FIFO order
    /// This ensures frames are decoded sequentially, preventing P-frame decode errors
    var frameProcessingTask: Task<Void, Never>?

    /// Total decoded frames (lifetime)
    var decodedFrameCount: UInt64 = 0
    /// Recent decode timestamps for FPS sampling
    var fpsSampleTimes: [CFAbsoluteTime] = []
    /// Latest computed FPS sample
    var currentFPS: Double = 0
    /// Total reassembled frames (lifetime)
    var receivedFrameCount: UInt64 = 0
    /// Recent receive timestamps for FPS sampling
    var receiveSampleTimes: [CFAbsoluteTime] = []
    /// Latest computed receive FPS sample
    var currentReceiveFPS: Double = 0
    var lastMetricsLogTime: CFAbsoluteTime = 0
    var lastMetricsDispatchTime: CFAbsoluteTime = 0
    static let metricsDispatchInterval: TimeInterval = 0.5

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
    private(set) var onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil

    /// Called when the first frame is decoded for a stream.
    private(set) var onFirstFrame: (@MainActor @Sendable () -> Void)?

    /// Called when input blocking state changes (true = block input, false = allow input)
    /// Input should be blocked when decoder is in a bad state (awaiting keyframe, decode errors)
    private(set) var onInputBlockingChanged: (@MainActor @Sendable (Bool) -> Void)?

    /// Current input blocking state - true when decoder is unhealthy
    var isInputBlocked: Bool = false

    /// Set callbacks for stream events
    func setCallbacks(
        onKeyframeNeeded: (@MainActor @Sendable () -> Void)?,
        onResizeEvent: (@MainActor @Sendable (ResizeEvent) -> Void)?,
        onResizeStateChanged: (@MainActor @Sendable (ResizeState) -> Void)? = nil,
        onFrameDecoded: (@MainActor @Sendable (ClientFrameMetrics) -> Void)? = nil,
        onFirstFrame: (@MainActor @Sendable () -> Void)? = nil,
        onInputBlockingChanged: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeEvent = onResizeEvent
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
        self.onFirstFrame = onFirstFrame
        self.onInputBlockingChanged = onInputBlockingChanged
    }

    // MARK: - Initialization

    /// Create a new stream controller
    init(streamID: StreamID, maxPayloadSize: Int) {
        self.streamID = streamID
        self.decoder = HEVCDecoder()
        self.reassembler = FrameReassembler(streamID: streamID, maxPayloadSize: maxPayloadSize)
    }

    /// Start the controller - sets up decoder and reassembler callbacks
    func start() async {
        // Set up error recovery - request keyframe when decode errors exceed threshold
        await decoder.setErrorThresholdHandler { [weak self] in
            guard let self else { return }
            Task {
                self.reassembler.enterKeyframeOnlyMode()
                await self.onKeyframeNeeded?()
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

        // Set up input blocking handler - block input when decoder is unhealthy
        await decoder.setInputBlockingHandler { [weak self] isBlocked in
            guard let self else { return }
            Task {
                await self.updateInputBlocking(isBlocked)
            }
        }

        // Set up frame handler
        await decoder.startDecoding { [weak self] (pixelBuffer: CVPixelBuffer, presentationTime: CMTime, contentRect: CGRect) in
            guard let self else { return }

            // Also store in global cache for iOS gesture tracking compatibility
            let (metalTexture, texture) = self.textureCache.makeTexture(from: pixelBuffer)
            MirageFrameCache.shared.store(
                pixelBuffer,
                contentRect: contentRect,
                metalTexture: metalTexture,
                texture: texture,
                for: capturedStreamID
            )
            MirageRenderScheduler.shared.signalFrame(for: capturedStreamID)

            // Mark that we've received a frame and notify delegate
            Task { [weak self] in
                guard let self else { return }
                await self.recordDecodedFrame()
                await self.markFirstFrameReceived()
                await notifyFrameDecoded()
            }
        }

        await startFrameProcessingPipeline()
    }

    func startFrameProcessingPipeline() async {
        // Create AsyncStream for ordered frame processing
        // This ensures frames are decoded in the order they were received,
        // preventing P-frame decode errors caused by out-of-order Task execution
        let (stream, continuation) = AsyncStream.makeStream(of: FrameData.self, bufferingPolicy: .unbounded)
        frameContinuation = continuation

        // Start the frame processing task - single task processes all frames sequentially
        let capturedDecoder = decoder
        frameProcessingTask = Task { [weak self] in
            for await frame in stream {
                defer { frame.releaseBuffer() }
                guard self != nil else { continue }
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

        // Set up reassembler callback - yields frames to AsyncStream for ordered processing
        let recordReceivedFrame: @Sendable () -> Void = { [weak self] in
            Task { await self?.recordReceivedFrame() }
        }
        let reassemblerHandler: @Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void) -> Void = { _, frameData, isKeyframe, timestamp, contentRect, releaseBuffer in
            let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            recordReceivedFrame()

            // Yield to stream instead of creating a new Task
            // AsyncStream maintains FIFO order, ensuring frames are decoded sequentially
            continuation.yield(FrameData(
                data: frameData,
                presentationTime: presentationTime,
                isKeyframe: isKeyframe,
                contentRect: contentRect,
                releaseBuffer: releaseBuffer
            ))
        }
        reassembler.setFrameHandler(reassemblerHandler)
    }

    func stopFrameProcessingPipeline() {
        frameContinuation?.finish()
        frameContinuation = nil
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
    }

    /// Stop the controller and clean up resources
    func stop() async {
        // Stop frame processing - finish stream and cancel task
        stopFrameProcessingPipeline()

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        MirageFrameCache.shared.clear(for: streamID)
    }

    /// Record a decoded frame (used for FPS sampling).
    private func recordDecodedFrame() {
        decodedFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        currentFPS = updateSampleTimes(&fpsSampleTimes, now: now)
    }

    private func recordReceivedFrame() {
        receivedFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        currentReceiveFPS = updateSampleTimes(&receiveSampleTimes, now: now)
    }

    func getCurrentFPS() -> Double {
        currentFPS
    }

    private func notifyFrameDecoded() async {
        let now = CFAbsoluteTimeGetCurrent()
        if lastMetricsDispatchTime > 0, now - lastMetricsDispatchTime < Self.metricsDispatchInterval {
            return
        }

        lastMetricsDispatchTime = now
        let decodedFPS = currentFPS
        let receivedFPS = currentReceiveFPS
        let droppedFrames = reassembler.getDroppedFrameCount()
        logMetricsIfNeeded(droppedFrames: droppedFrames)
        let metrics = ClientFrameMetrics(
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            droppedFrames: droppedFrames
        )
        let callback = onFrameDecoded
        await MainActor.run {
            callback?(metrics)
        }
    }
}
