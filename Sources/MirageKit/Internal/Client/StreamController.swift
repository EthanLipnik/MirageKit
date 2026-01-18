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

    // MARK: - Properties

    /// The stream this controller manages
    let streamID: StreamID

    /// HEVC decoder for this stream
    private let decoder: HEVCDecoder

    /// Frame reassembler for this stream
    private let reassembler: FrameReassembler

    /// Thread-safe frame storage for non-actor access (Metal draw loop)
    private let frameStorage = StreamFrameStorage()

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

    /// Pending resize debounce task
    private var resizeDebounceTask: Task<Void, Never>?

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
    private(set) var onFrameDecoded: (@MainActor @Sendable (Double) -> Void)? = nil

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
        onFrameDecoded: (@MainActor @Sendable (Double) -> Void)? = nil,
        onInputBlockingChanged: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onResizeEvent = onResizeEvent
        self.onResizeStateChanged = onResizeStateChanged
        self.onFrameDecoded = onFrameDecoded
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
        let capturedFrameStorage = frameStorage
        await decoder.startDecoding { [weak self] (pixelBuffer: CVPixelBuffer, presentationTime: CMTime, contentRect: CGRect) in
            guard let self else { return }

            // Store in thread-safe storage for Metal view pull-based access
            capturedFrameStorage.store(pixelBuffer, contentRect: contentRect)

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

        // Set up reassembler callback - yields frames to AsyncStream for ordered processing
        let capturedContinuation = frameContinuation
        let reassemblerHandler: @Sendable (StreamID, Data, Bool, UInt64, CGRect) -> Void = { _, frameData, isKeyframe, timestamp, contentRect in
            // CRITICAL: Force copy data BEFORE yielding to stream
            // Swift's Data uses copy-on-write, so we must ensure a real copy exists
            // that survives until the frame is processed. The original frameData from the
            // reassembler may be deallocated by ARC before processing completes.
            let copiedData = frameData.withUnsafeBytes { Data($0) }
            let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)

            // Yield to stream instead of creating a new Task
            // AsyncStream maintains FIFO order, ensuring frames are decoded sequentially
            capturedContinuation?.yield(FrameData(
                data: copiedData,
                presentationTime: presentationTime,
                isKeyframe: isKeyframe,
                contentRect: contentRect
            ))
        }
        await reassembler.setFrameHandler(reassemblerHandler)
    }

    /// Stop the controller and clean up resources
    func stop() async {
        // Stop frame processing - finish stream and cancel task
        frameContinuation?.finish()
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        frameContinuation = nil

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        frameStorage.clear()
        MirageFrameCache.shared.clear(for: streamID)
    }

    /// Record a decoded frame (used for FPS sampling).
    private func recordDecodedFrame() {
        decodedFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        fpsSampleTimes.append(now)
        let cutoff = now - 1.0
        if let firstValid = fpsSampleTimes.firstIndex(where: { $0 >= cutoff }) {
            if firstValid > 0 {
                fpsSampleTimes.removeFirst(firstValid)
            }
        } else {
            fpsSampleTimes.removeAll()
        }
        currentFPS = Double(fpsSampleTimes.count)
    }

    func getCurrentFPS() -> Double {
        currentFPS
    }

    private func notifyFrameDecoded() async {
        let fps = currentFPS
        let callback = onFrameDecoded
        await MainActor.run {
            callback?(fps)
        }
    }

    // MARK: - Frame Access

    /// Get the latest frame (thread-safe, for Metal draw loop)
    nonisolated func getLatestFrame() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)? {
        frameStorage.get()
    }

    // MARK: - Decoder Control

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        await decoder.resetForNewSession()
        await reassembler.reset()
        decodedFrameCount = 0
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
        await reassembler.reset()
        Task { @MainActor [weak self] in
            await self?.onKeyframeNeeded?()
        }
    }

    // MARK: - Private Helpers

    private func markFirstFrameReceived() {
        hasReceivedFirstFrame = true
    }

    /// Update input blocking state and notify callback
    private func updateInputBlocking(_ isBlocked: Bool) {
        guard self.isInputBlocked != isBlocked else { return }
        self.isInputBlocked = isBlocked
        MirageLogger.client("Input blocking state changed: \(isBlocked ? "BLOCKED" : "allowed") for stream \(streamID)")
        Task { @MainActor [weak self] in
            await self?.onInputBlockingChanged?(isBlocked)
        }
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

// MARK: - Stream Frame Storage

/// Thread-safe storage for a single stream's latest frame
/// Separate from the global MirageFrameCache to allow per-controller storage
final class StreamFrameStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: (pixelBuffer: CVPixelBuffer, contentRect: CGRect)?

    func store(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect) {
        lock.lock()
        frame = (pixelBuffer, contentRect)
        lock.unlock()
    }

    func get() -> (pixelBuffer: CVPixelBuffer, contentRect: CGRect)? {
        lock.lock()
        let result = frame
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        frame = nil
        lock.unlock()
    }
}
