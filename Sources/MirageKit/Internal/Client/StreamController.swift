//
//  StreamController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/15/26.
//

import Foundation
import CoreMedia
import CoreVideo

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
    private struct FrameData: Sendable {
        let data: Data
        let presentationTime: CMTime
        let isKeyframe: Bool
        let contentRect: CGRect
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
    private let decoder: HEVCDecoder

    /// Frame reassembler for this stream
    private let reassembler: FrameReassembler

    /// Current resize state
    private(set) var resizeState: ResizeState = .idle

    /// Last sent resize parameters for deduplication
    private var lastSentAspectRatio: CGFloat = 0
    private var lastSentRelativeScale: CGFloat = 0
    private var lastSentPixelSize: CGSize = .zero

    /// Maximum resolution (5K cap)
    private static let maxResolutionWidth: CGFloat = 5120
    private static let maxResolutionHeight: CGFloat = 2880

    /// Debounce delay for resize events
    private static let resizeDebounceDelay: Duration = .milliseconds(200)

    /// Timeout for resize confirmation
    private static let resizeTimeout: Duration = .seconds(2)

    /// Interval for retrying keyframe requests while decoder is unhealthy
    private static let keyframeRecoveryInterval: Duration = .seconds(1)

    /// Pending resize debounce task
    private var resizeDebounceTask: Task<Void, Never>?

    /// Task that periodically requests keyframes during decoder recovery
    private var keyframeRecoveryTask: Task<Void, Never>?
    private var lastRecoveryRequestTime: CFAbsoluteTime = 0

    /// Whether we've received at least one frame
    private var hasReceivedFirstFrame = false

    /// AsyncStream continuation for ordered frame delivery
    /// Frames are yielded here and processed sequentially by frameProcessingTask
    private var frameContinuation: AsyncStream<FrameData>.Continuation?

    /// Task that processes frames from the stream in FIFO order
    /// This ensures frames are decoded sequentially, preventing P-frame decode errors
    private var frameProcessingTask: Task<Void, Never>?

    /// Total decoded frames (lifetime)
    private var decodedFrameCount: UInt64 = 0
    /// Recent decode timestamps for FPS sampling
    private var fpsSampleTimes: [CFAbsoluteTime] = []
    /// Latest computed FPS sample
    private var currentFPS: Double = 0
    /// Total reassembled frames (lifetime)
    private var receivedFrameCount: UInt64 = 0
    /// Recent receive timestamps for FPS sampling
    private var receiveSampleTimes: [CFAbsoluteTime] = []
    /// Latest computed receive FPS sample
    private var currentReceiveFPS: Double = 0
    private var lastMetricsLogTime: CFAbsoluteTime = 0
    private var lastMetricsDispatchTime: CFAbsoluteTime = 0
    private static let metricsDispatchInterval: TimeInterval = 0.5

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
    private(set) var isInputBlocked: Bool = false

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
    init(streamID: StreamID) {
        self.streamID = streamID
        self.decoder = HEVCDecoder()
        self.reassembler = FrameReassembler(streamID: streamID)
    }

    /// Start the controller - sets up decoder and reassembler callbacks
    func start() async {
        // Set up error recovery - request keyframe when decode errors exceed threshold
        await decoder.setErrorThresholdHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.reassembler.enterKeyframeOnlyMode()
                await self.onKeyframeNeeded?()
            }
        }

        // Set up dimension change handler - reset reassembler when dimensions change
        let capturedStreamID = streamID
        await decoder.setDimensionChangeHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.reassembler.reset()
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
            MirageFrameCache.shared.store(pixelBuffer, contentRect: contentRect, for: capturedStreamID)

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

    private func startFrameProcessingPipeline() async {
        // Create AsyncStream for ordered frame processing
        // This ensures frames are decoded in the order they were received,
        // preventing P-frame decode errors caused by out-of-order Task execution
        let (stream, continuation) = AsyncStream.makeStream(of: FrameData.self, bufferingPolicy: .unbounded)
        frameContinuation = continuation

        // Start the frame processing task - single task processes all frames sequentially
        let capturedDecoder = decoder
        frameProcessingTask = Task { [weak self] in
            for await frame in stream {
                guard self != nil else { break }
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
        let reassemblerHandler: @Sendable (StreamID, Data, Bool, UInt64, CGRect) -> Void = { _, frameData, isKeyframe, timestamp, contentRect in
            // CRITICAL: Force copy data BEFORE yielding to stream
            // Swift's Data uses copy-on-write, so we must ensure a real copy exists
            // that survives until the frame is processed. The original frameData from the
            // reassembler may be deallocated by ARC before processing completes.
            let copiedData = frameData.withUnsafeBytes { Data($0) }
            let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            recordReceivedFrame()

            // Yield to stream instead of creating a new Task
            // AsyncStream maintains FIFO order, ensuring frames are decoded sequentially
            continuation.yield(FrameData(
                data: copiedData,
                presentationTime: presentationTime,
                isKeyframe: isKeyframe,
                contentRect: contentRect
            ))
        }
        await reassembler.setFrameHandler(reassemblerHandler)
    }

    private func stopFrameProcessingPipeline() {
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
        let droppedFrames = await reassembler.getDroppedFrameCount()
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

    // MARK: - Decoder Control

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        await reassembler.reset()
        decodedFrameCount = 0
        currentFPS = 0
        fpsSampleTimes.removeAll()
        receivedFrameCount = 0
        currentReceiveFPS = 0
        receiveSampleTimes.removeAll()
        lastMetricsLogTime = 0
        lastMetricsDispatchTime = 0
        await startFrameProcessingPipeline()
    }

    private func updateSampleTimes(_ sampleTimes: inout [CFAbsoluteTime], now: CFAbsoluteTime) -> Double {
        sampleTimes.append(now)
        let cutoff = now - 1.0
        if let firstValid = sampleTimes.firstIndex(where: { $0 >= cutoff }) {
            if firstValid > 0 {
                sampleTimes.removeFirst(firstValid)
            }
        } else {
            sampleTimes.removeAll()
        }
        return Double(sampleTimes.count)
    }

    private func logMetricsIfNeeded(droppedFrames: UInt64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard MirageLogger.isEnabled(.client) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = currentFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = currentReceiveFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client("Client FPS: decoded=\(decodedText), received=\(receivedText), dropped=\(droppedFrames), stream=\(streamID)")
        lastMetricsLogTime = now
    }

    /// Get the reassembler for packet routing
    func getReassembler() -> FrameReassembler {
        reassembler
    }

    // MARK: - Resize Handling

    /// Handle drawable size change from Metal layer
    /// - Parameters:
    ///   - pixelSize: New drawable size in pixels
    ///   - screenBounds: Screen bounds in points
    ///   - scaleFactor: Screen scale factor
    func handleDrawableSizeChanged(
        _ pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    ) async {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        // Only enter resize mode after first frame
        if hasReceivedFirstFrame {
            await setResizeState(.awaiting(expectedSize: pixelSize))
        }

        // Cancel pending debounce
        resizeDebounceTask?.cancel()

        // Debounce resize
        resizeDebounceTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: Self.resizeDebounceDelay)
            } catch {
                return // Cancelled
            }

            await self.processResizeEvent(pixelSize: pixelSize, screenBounds: screenBounds, scaleFactor: scaleFactor)
        }
    }

    /// Called when host confirms resize (sends new min size)
    func confirmResize(newMinSize: CGSize) async {
        if case .awaiting = resizeState {
            await setResizeState(.confirmed(finalSize: newMinSize))
            // Brief delay then return to idle
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                await self?.setResizeState(.idle)
            }
        }
    }

    /// Force clear resize state (e.g., when returning from background)
    func clearResizeState() async {
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        await setResizeState(.idle)
    }

    /// Request stream recovery (keyframe + reassembler reset)
    func requestRecovery() async {
        await clearResizeState()
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        await reassembler.reset()
        await reassembler.enterKeyframeOnlyMode()
        await startFrameProcessingPipeline()
        Task { @MainActor [weak self] in
            await self?.onKeyframeNeeded?()
        }
    }

    // MARK: - Private Helpers

    private func markFirstFrameReceived() {
        guard !hasReceivedFirstFrame else { return }
        hasReceivedFirstFrame = true
        Task { @MainActor [weak self] in
            await self?.onFirstFrame?()
        }
    }

    /// Update input blocking state and notify callback
    private func updateInputBlocking(_ isBlocked: Bool) {
        guard self.isInputBlocked != isBlocked else { return }
        self.isInputBlocked = isBlocked
        MirageLogger.client("Input blocking state changed: \(isBlocked ? "BLOCKED" : "allowed") for stream \(streamID)")
        if isBlocked {
            startKeyframeRecoveryLoop()
        } else {
            stopKeyframeRecoveryLoop()
        }
        Task { @MainActor [weak self] in
            await self?.onInputBlockingChanged?(isBlocked)
        }
    }

    private func startKeyframeRecoveryLoop() {
        guard keyframeRecoveryTask == nil else { return }
        keyframeRecoveryTask = Task { [weak self] in
            await self?.runKeyframeRecoveryLoop()
        }
    }

    private func stopKeyframeRecoveryLoop() {
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        lastRecoveryRequestTime = 0
    }

    private func runKeyframeRecoveryLoop() async {
        while isInputBlocked && !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.keyframeRecoveryInterval)
            } catch {
                break
            }
            guard isInputBlocked && !Task.isCancelled else { break }
            let now = CFAbsoluteTimeGetCurrent()
            guard let awaitingDuration = await reassembler.awaitingKeyframeDuration(now: now) else { continue }
            let timeout = await reassembler.keyframeTimeoutSeconds()
            guard awaitingDuration >= timeout else { continue }
            if lastRecoveryRequestTime > 0, now - lastRecoveryRequestTime < timeout {
                continue
            }
            guard let handler = onKeyframeNeeded else { break }
            lastRecoveryRequestTime = now
            await MainActor.run {
                handler()
            }
        }
        keyframeRecoveryTask = nil
    }

    private func setResizeState(_ newState: ResizeState) async {
        guard resizeState != newState else { return }
        resizeState = newState

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onResizeStateChanged?(newState)
        }
    }

    private func processResizeEvent(
        pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    ) async {
        // Calculate aspect ratio
        let aspectRatio = pixelSize.width / pixelSize.height

        // Apply 5K resolution cap while preserving aspect ratio
        var cappedSize = pixelSize
        if cappedSize.width > Self.maxResolutionWidth {
            cappedSize.width = Self.maxResolutionWidth
            cappedSize.height = cappedSize.width / aspectRatio
        }
        if cappedSize.height > Self.maxResolutionHeight {
            cappedSize.height = Self.maxResolutionHeight
            cappedSize.width = cappedSize.height * aspectRatio
        }

        // Round to even dimensions for HEVC codec
        cappedSize.width = floor(cappedSize.width / 2) * 2
        cappedSize.height = floor(cappedSize.height / 2) * 2
        let cappedPixelSize = CGSize(width: cappedSize.width, height: cappedSize.height)

        // Calculate relative scale
        let drawablePointSize = CGSize(
            width: cappedSize.width / scaleFactor,
            height: cappedSize.height / scaleFactor
        )
        let drawableArea = drawablePointSize.width * drawablePointSize.height
        let screenArea = screenBounds.width * screenBounds.height
        let relativeScale = min(1.0, drawableArea / screenArea)

        // Skip initial layout (prevents decoder P-frame discard mode on first draw)
        let isInitialLayout = lastSentAspectRatio == 0 && lastSentRelativeScale == 0 && lastSentPixelSize == .zero
        if isInitialLayout {
            lastSentAspectRatio = aspectRatio
            lastSentRelativeScale = relativeScale
            lastSentPixelSize = cappedPixelSize
            await setResizeState(.idle)
            return
        }

        // Check if changed significantly
        let aspectChanged = abs(aspectRatio - lastSentAspectRatio) > 0.01
        let scaleChanged = abs(relativeScale - lastSentRelativeScale) > 0.01
        let pixelChanged = cappedPixelSize != lastSentPixelSize
        guard aspectChanged || scaleChanged || pixelChanged else {
            await setResizeState(.idle)
            return
        }

        // Update last sent values
        lastSentAspectRatio = aspectRatio
        lastSentRelativeScale = relativeScale
        lastSentPixelSize = cappedPixelSize

        let event = ResizeEvent(
            aspectRatio: aspectRatio,
            relativeScale: relativeScale,
            clientScreenSize: screenBounds,
            pixelWidth: Int(cappedSize.width),
            pixelHeight: Int(cappedSize.height)
        )

        Task { @MainActor [weak self] in
            await self?.onResizeEvent?(event)
        }

        // Fallback timeout
        do {
            try await Task.sleep(for: Self.resizeTimeout)
            if case .awaiting = resizeState {
                await setResizeState(.idle)
            }
        } catch {
            // Cancelled, ignore
        }
    }
}
