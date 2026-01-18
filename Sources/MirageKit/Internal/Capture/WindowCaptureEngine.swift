import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

/// Manages window capture using ScreenCaptureKit
/// Frame information passed from capture to encoding
struct CapturedFrameInfo: Sendable {
    /// The pixel buffer content area (excluding black padding)
    let contentRect: CGRect
    /// Regions that changed since the last frame (in pixel coordinates)
    let dirtyRects: [CGRect]
    /// Total area of dirty regions as percentage of frame (0-100)
    let dirtyPercentage: Float
    /// Keepalive frame - must be encoded even if 0% dirty to maintain stream continuity
    /// Set for fallback frames sent during SCK pauses (menus, drags)
    let isKeepalive: Bool

    init(contentRect: CGRect, dirtyRects: [CGRect], dirtyPercentage: Float, isKeepalive: Bool = false) {
        self.contentRect = contentRect
        self.dirtyRects = dirtyRects
        self.dirtyPercentage = dirtyPercentage
        self.isKeepalive = isKeepalive
    }
}

actor WindowCaptureEngine {
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private let configuration: MirageEncoderConfiguration
    private var pendingKeyframeRequest = false
    private var isCapturing = false
    private var capturedFrameHandler: (@Sendable (CMSampleBuffer, CapturedFrameInfo) -> Void)?
    private var dimensionChangeHandler: (@Sendable (Int, Int) -> Void)?

    // Track current dimensions to detect changes
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentScaleFactor: CGFloat = 1.0
    private var outputScale: CGFloat = 1.0
    private var useBestCaptureResolution: Bool = true
    private var contentFilter: SCContentFilter?
 
    init(configuration: MirageEncoderConfiguration) {
        self.configuration = configuration
    }

    private static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }


    /// Start capturing all windows belonging to an application (includes alerts, sheets, dialogs)
    /// - Parameters:
    ///   - knownScaleFactor: Override scale factor for virtual displays (NSScreen detection fails on headless Macs)
    func startCapture(
        window: SCWindow,
        application: SCRunningApplication,
        display: SCDisplay,
        knownScaleFactor: CGFloat? = nil,
        outputScale: CGFloat = 1.0,
        onFrame: @escaping @Sendable (CMSampleBuffer, CapturedFrameInfo) -> Void,
        onDimensionChange: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        guard !isCapturing else {
            throw MirageError.protocolError("Already capturing")
        }

        capturedFrameHandler = onFrame
        dimensionChangeHandler = onDimensionChange

        // Create stream configuration
        let streamConfig = SCStreamConfiguration()

        // Calculate target dimensions based on window frame
        // Use known scale factor if provided (for virtual displays on headless Macs),
        // otherwise detect from NSScreen
        let target: StreamTargetDimensions
        if let knownScale = knownScaleFactor {
            target = streamTargetDimensions(windowFrame: window.frame, scaleFactor: knownScale)
        } else {
            target = streamTargetDimensions(windowFrame: window.frame)
        }

        let clampedScale = max(0.1, min(1.0, outputScale))
        self.outputScale = clampedScale
        currentScaleFactor = target.hostScaleFactor * clampedScale
        currentWidth = Self.alignedEvenPixel(CGFloat(target.width) * clampedScale)
        currentHeight = Self.alignedEvenPixel(CGFloat(target.height) * clampedScale)

        // CRITICAL: For virtual displays on headless Macs, do NOT use .best or .nominal
        // as they may capture at wrong resolution (1x instead of 2x).
        // Setting explicit width/height WITHOUT captureResolution lets SCK use our dimensions.
        // For real displays, .best correctly detects backing scale factor.
        useBestCaptureResolution = (knownScaleFactor == nil)
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        // When knownScaleFactor is set, we intentionally don't set captureResolution
        // to let our explicit width/height control the output resolution
        streamConfig.width = currentWidth
        streamConfig.height = currentHeight

        MirageLogger.capture("Configuring capture: \(currentWidth)x\(currentHeight), scale=\(currentScaleFactor), outputScale=\(clampedScale), knownScale=\(String(describing: knownScaleFactor))")

        // Frame rate
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.targetFrameRate)
        )

        // Color and format - 10-bit for full color gamut (P3)
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        switch configuration.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }
        // TODO: HDR support - add .hdr case when EDR configuration is figured out

        // Capture settings
        streamConfig.showsCursor = false  // Don't capture cursor - iPad shows its own
        streamConfig.queueDepth = 5       // Buffer through brief SCK pauses during drags/menus

        // Use window-level capture for precise dimensions (captures just this window)
        // Note: This may not capture modal dialogs/sheets, but avoids black bars from app-level bounding box
        let filter = SCContentFilter(desktopIndependentWindow: window)
        self.contentFilter = filter

        let windowTitle = window.title ?? "untitled"
        MirageLogger.capture("Starting capture at \(currentWidth)x\(currentHeight) (scale: \(currentScaleFactor)) for window: \(windowTitle)")

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else {
            throw MirageError.protocolError("Failed to create stream")
        }

        // Create output handler with windowID for fallback capture during SCK pauses
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onKeyframeRequest: { [weak self] in
                Task { await self?.markKeyframeRequested() }
            },
            windowID: window.windowID
        )

        // Use nil queue (like Ensemble) to avoid blocking encoder during drags/menus
        // The default queue handles frame delivery without stalling the capture pipeline
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: nil
        )

        // Start capturing
        try await stream.startCapture()
        isCapturing = true
    }

    /// Stop capturing
    func stopCapture() async {
        guard isCapturing else { return }

        do {
            try await stream?.stopCapture()
        } catch {
            MirageLogger.error(.capture, "Error stopping capture: \(error)")
        }

        stream = nil
        streamOutput = nil
        capturedFrameHandler = nil
        isCapturing = false
    }

    /// Update stream dimensions when the host window is resized
    /// Output resolution can be scaled for bandwidth savings.
    func updateDimensions(windowFrame: CGRect, outputScale: CGFloat? = nil) async throws {
        guard isCapturing, let stream else { return }

        let target = streamTargetDimensions(windowFrame: windowFrame)
        let scale = max(0.1, min(1.0, outputScale ?? self.outputScale))
        self.outputScale = scale
        currentScaleFactor = target.hostScaleFactor * scale
        let newWidth = Self.alignedEvenPixel(CGFloat(target.width) * scale)
        let newHeight = Self.alignedEvenPixel(CGFloat(target.height) * scale)

        // Don't update if dimensions haven't actually changed
        guard newWidth != currentWidth || newHeight != currentHeight else { return }

        // Clear cached fallback frame to prevent stale data during resize
        streamOutput?.clearCache()

        MirageLogger.capture("Updating dimensions from \(currentWidth)x\(currentHeight) to \(newWidth)x\(newHeight) (scale: \(currentScaleFactor), outputScale: \(scale))")

        currentWidth = newWidth
        currentHeight = newHeight

        // Create new stream configuration with updated dimensions
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.targetFrameRate)
        )
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 5  // Buffer through brief SCK pauses during drags/menus

        // Update the stream configuration
        try await stream.updateConfiguration(streamConfig)
        MirageLogger.capture("Stream configuration updated to \(newWidth)x\(newHeight)")
    }

    /// Update capture resolution to specific pixel dimensions (independent of window size)
    /// This allows the client to request exact resolution regardless of host window constraints
    func updateResolution(width: Int, height: Int) async throws {
        guard isCapturing, let stream else { return }

        // Don't update if dimensions haven't actually changed
        guard width != currentWidth || height != currentHeight else { return }

        // Clear cached fallback frame to prevent stale data during resize
        // This avoids sending old-resolution frames during SCK pause after config update
        streamOutput?.clearCache()

        MirageLogger.capture("Updating resolution to client-requested \(width)x\(height) (was \(currentWidth)x\(currentHeight))")

        currentWidth = width
        currentHeight = height

        // Create new stream configuration with client's exact pixel dimensions
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.targetFrameRate)
        )
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 5  // Buffer through brief SCK pauses during drags/menus

        try await stream.updateConfiguration(streamConfig)
        MirageLogger.capture("Resolution updated to client dimensions: \(width)x\(height)")
    }

    /// Update the display being captured (after virtual display recreation)
    /// Uses SCStream.updateContentFilter to switch to the new display without restarting
    func updateCaptureDisplay(_ newDisplay: SCDisplay, resolution: CGSize) async throws {
        guard isCapturing, let stream else { return }

        // Clear cached fallback frame when switching displays
        streamOutput?.clearCache()

        let newWidth = Int(resolution.width)
        let newHeight = Int(resolution.height)

        MirageLogger.capture("Switching capture to new display \(newDisplay.displayID) at \(newWidth)x\(newHeight)")

        // Update dimensions
        currentWidth = newWidth
        currentHeight = newHeight

        // Create new filter for the new display
        let newFilter = SCContentFilter(display: newDisplay, excludingWindows: [])
        self.contentFilter = newFilter

        // Create configuration for the new display
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.targetFrameRate)
        )
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 5  // Buffer through brief SCK pauses during drags/menus

        // Apply both filter and configuration updates
        try await stream.updateContentFilter(newFilter)
        try await stream.updateConfiguration(streamConfig)

        MirageLogger.capture("Capture switched to display \(newDisplay.displayID) at \(newWidth)x\(newHeight)")
    }

    /// Update the capture frame rate dynamically (for activity-based throttling)
    /// - Parameter fps: Target frame rate (1 = throttled for inactive windows, normal = active)
    func updateFrameRate(_ fps: Int) async throws {
        guard isCapturing, let stream else { return }

        MirageLogger.capture("Updating frame rate to \(fps) fps")

        // Create new stream configuration with updated frame rate
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        streamConfig.width = currentWidth
        streamConfig.height = currentHeight
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(fps)
        )
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 5  // Buffer through brief SCK pauses during drags/menus

        try await stream.updateConfiguration(streamConfig)
        MirageLogger.capture("Frame rate updated to \(fps) fps")
    }

    /// Get current capture dimensions
    func getCurrentDimensions() -> (width: Int, height: Int) {
        (currentWidth, currentHeight)
    }

    /// Start capturing an entire display (for login screen streaming)
    /// This captures everything rendered on the display, not just a single window
    /// Start capturing a display (used for login screen and desktop streaming)
    /// - Parameters:
    ///   - display: The display to capture
    ///   - resolution: Optional pixel resolution override (used for HiDPI virtual displays)
    ///   - showsCursor: Whether to show cursor in captured frames (true for login, false for desktop streaming)
    ///   - onFrame: Callback for each captured frame
    ///   - onDimensionChange: Callback when dimensions change
    func startDisplayCapture(
        display: SCDisplay,
        resolution: CGSize? = nil,
        showsCursor: Bool = true,
        onFrame: @escaping @Sendable (CMSampleBuffer, CapturedFrameInfo) -> Void,
        onDimensionChange: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        guard !isCapturing else {
            throw MirageError.protocolError("Already capturing")
        }

        capturedFrameHandler = onFrame
        dimensionChangeHandler = onDimensionChange

        // Create stream configuration for display capture
        let streamConfig = SCStreamConfiguration()

        // Use display's native resolution or the explicit pixel override (for HiDPI virtual displays)
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        currentWidth = max(1, Int(captureResolution.width))
        currentHeight = max(1, Int(captureResolution.height))

        // Calculate scale factor: if resolution was explicitly provided (HiDPI override),
        // compare it to display's reported dimensions to determine the scale
        // For HiDPI virtual displays: resolution=2064x2752 (pixels), display.width/height=1032x1376 (points) → scale=2.0
        if let res = resolution, display.width > 0 {
            currentScaleFactor = res.width / CGFloat(display.width)
        } else {
            currentScaleFactor = 1.0
        }

        // CRITICAL: For HiDPI displays, force ScreenCaptureKit to capture at pixel resolution
        // Without this, SCK captures at logical (point) resolution and we get half-res frames
        // .best tells SCK to use the highest available resolution (pixel resolution for Retina/HiDPI)
        useBestCaptureResolution = currentScaleFactor > 1.0
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
            MirageLogger.capture("HiDPI capture: scale=\(currentScaleFactor), forcing captureResolution=.best")
        }

        streamConfig.width = currentWidth
        streamConfig.height = currentHeight

        // Frame rate
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.targetFrameRate)
        )

        // Color and format - 10-bit for full color gamut (P3)
        streamConfig.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        switch configuration.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }
        // TODO: HDR support - add .hdr case when EDR configuration is figured out

        // Capture settings - cursor visibility depends on use case:
        // - Login screen: show cursor (true) for user interaction
        // - Desktop streaming: hide cursor (false) - client renders its own
        streamConfig.showsCursor = showsCursor
        streamConfig.queueDepth = 5  // Buffer through brief SCK pauses during drags/menus

        // Capture displayID before creating filter (for logging after)
        let capturedDisplayID = display.displayID

        // Create filter for the entire display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.contentFilter = filter

        MirageLogger.capture("Starting display capture at \(currentWidth)x\(currentHeight) for display \(capturedDisplayID)")

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else {
            throw MirageError.protocolError("Failed to create display stream")
        }

        // Create output handler (reduced keepalive rate for display capture)
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onKeyframeRequest: { [weak self] in
                Task { await self?.markKeyframeRequested() }
            },
            frameGapThreshold: 0.300,
            keepaliveInterval: 1.5,
            cacheInterval: 0.5
        )

        // Use nil queue (like Ensemble) to avoid blocking encoder during drags/menus
        // The default queue handles frame delivery without stalling the capture pipeline
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: nil
        )

        // Start capturing
        try await stream.startCapture()
        isCapturing = true

        MirageLogger.capture("Display capture started for display \(display.displayID)")
    }

    /// Update configuration (requires restart)
    func updateConfiguration(_ newConfig: MirageEncoderConfiguration) async throws {
        // Would need to restart capture with new config
    }

    private func handleFrame(_ sampleBuffer: CMSampleBuffer, frameInfo: CapturedFrameInfo) {
        capturedFrameHandler?(sampleBuffer, frameInfo)
    }

    private func markKeyframeRequested() {
        pendingKeyframeRequest = true
    }

    func consumePendingKeyframeRequest() async -> Bool {
        if pendingKeyframeRequest {
            pendingKeyframeRequest = false
            return true
        }
        return false
    }
}

/// Stream output delegate
private final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (CMSampleBuffer, CapturedFrameInfo) -> Void
    private let onKeyframeRequest: @Sendable () -> Void
    private var frameCount: UInt64 = 0
    private var skippedIdleFrames: UInt64 = 0
    private var smallChangeFrames: UInt64 = 0  // Track frames with small dirty regions
    private var skippedByPixelDetection: UInt64 = 0  // Frames skipped by our pixel detector

    // DIAGNOSTIC: Track all frame statuses to debug drag/menu freeze issue
    private var statusCounts: [Int: UInt64] = [:]
    private var lastStatusLogTime: CFAbsoluteTime = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var maxFrameGap: CFAbsoluteTime = 0

    /// Legacy CPU-based detector (disabled due to SCK buffer reuse issue)
    private let dirtyDetector = DirtyRegionDetector()

    // Frame gap watchdog: when SCK stops delivering frames (during menus/drags),
    // cache the last frame and re-send it to keep the stream alive
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.mirage.capture.watchdog", qos: .userInteractive)
    private var windowID: CGWindowID = 0
    private var lastDeliveredFrameTime: CFAbsoluteTime = 0
    private var fallbackFrameCount: UInt64 = 0
    private let frameGapThreshold: CFAbsoluteTime
    private var lastKeepaliveTime: CFAbsoluteTime = 0
    private let keepaliveInterval: CFAbsoluteTime
    private let cacheInterval: CFAbsoluteTime
    private var lastCacheTime: CFAbsoluteTime = 0

    // Track if we've been in fallback mode - when SCK resumes, we may need a keyframe
    // to prevent decode errors from reference frame discontinuity
    private var wasInFallbackMode: Bool = false
    private var fallbackStartTime: CFAbsoluteTime = 0  // When fallback mode started
    private let fallbackLock = NSLock()

    // Only request keyframe if fallback lasted longer than this threshold
    // Brief fallbacks (<200ms) don't need keyframes - they're just normal SCK latency
    private let keyframeThreshold: CFAbsoluteTime = 0.200

    // Cached last frame for re-sending during gaps
    // We copy the pixel data since SCK may reuse buffers
    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedContentRect: CGRect = .zero
    private let cacheLock = NSLock()

    init(
        onFrame: @escaping @Sendable (CMSampleBuffer, CapturedFrameInfo) -> Void,
        onKeyframeRequest: @escaping @Sendable () -> Void,
        windowID: CGWindowID = 0,
        frameGapThreshold: CFAbsoluteTime = 0.100,
        keepaliveInterval: CFAbsoluteTime = 0.250,
        cacheInterval: CFAbsoluteTime = 0.100
    ) {
        self.onFrame = onFrame
        self.onKeyframeRequest = onKeyframeRequest
        self.windowID = windowID
        self.frameGapThreshold = frameGapThreshold
        self.keepaliveInterval = keepaliveInterval
        self.cacheInterval = cacheInterval
        super.init()
        startWatchdogTimer()
    }

    deinit {
        stopWatchdogTimer()
    }

    /// Start the watchdog timer that checks for frame gaps
    private func startWatchdogTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        // Check every 50ms for fallback during drag operations
        // Initial delay matches frameGapThreshold
        let initialDelayMs = max(50, Int(frameGapThreshold * 1000))
        timer.schedule(deadline: .now() + .milliseconds(initialDelayMs), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.checkForFrameGap()
        }
        timer.resume()
        watchdogTimer = timer
        MirageLogger.capture("Frame gap watchdog started (\(Int(frameGapThreshold * 1000))ms threshold, 50ms check interval)")
    }

    func stopWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    /// Clear the cached fallback frame (called during dimension changes)
    /// This prevents stale old-resolution frames from being sent during resize
    func clearCache() {
        cacheLock.lock()
        cachedPixelBuffer = nil
        cachedContentRect = .zero
        lastCacheTime = 0
        cacheLock.unlock()
        MirageLogger.capture("Cleared cached fallback frame for resize")
    }

    /// Check if SCK has stopped delivering frames and trigger fallback
    private func checkForFrameGap() {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastDeliveredFrameTime > 0 else { return }

        let gap = now - lastDeliveredFrameTime
        guard gap > frameGapThreshold else { return }

        // SCK has stopped delivering - re-send the cached frame
        resendCachedFrame()
    }

    /// Cache a copy of the pixel buffer for re-sending during gaps
    private func cacheFrame(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect) {
        guard cacheInterval > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastCacheTime > 0, now - lastCacheTime < cacheInterval {
            return
        }

        // Create a copy of the pixel buffer (SCK may reuse the original)
        guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else { return }
        lastCacheTime = now

        cacheLock.lock()
        cachedPixelBuffer = copiedBuffer
        cachedContentRect = contentRect
        cacheLock.unlock()
    }

    /// Copy a CVPixelBuffer to our own buffer
    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var destBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &destBuffer
        )

        guard status == kCVReturnSuccess, let dest = destBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        // Copy pixel data
        let srcAddr = CVPixelBufferGetBaseAddress(source)
        let dstAddr = CVPixelBufferGetBaseAddress(dest)
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dest)

        if srcBytesPerRow == dstBytesPerRow {
            // Fast path: same layout, single memcpy
            memcpy(dstAddr, srcAddr, srcBytesPerRow * height)
        } else {
            // Slow path: copy row by row
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
            for row in 0..<height {
                let srcRow = srcAddr! + row * srcBytesPerRow
                let dstRow = dstAddr! + row * dstBytesPerRow
                memcpy(dstRow, srcRow, copyBytes)
            }
        }

        return dest
    }

    /// Re-send cached frame when SCK stops delivering
    /// Note: CGWindowListCreateImage was deprecated in macOS 15, so we rely on
    /// queueDepth (2) and fallback frame re-sending during SCK pauses.
    private func resendCachedFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastKeepaliveTime > 0, now - lastKeepaliveTime < keepaliveInterval {
            return
        }

        // Mark that we're in fallback mode and record start time
        fallbackLock.lock()
        if !wasInFallbackMode {
            // First fallback frame - record when fallback started
            fallbackStartTime = now
        }
        wasInFallbackMode = true
        fallbackLock.unlock()

        cacheLock.lock()
        guard let pixelBuffer = cachedPixelBuffer else {
            cacheLock.unlock()
            MirageLogger.capture("Fallback: no cached frame available")
            return
        }
        let contentRect = cachedContentRect
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        cacheLock.unlock()

        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            MirageLogger.capture("Fallback: failed to create sample buffer from cached frame")
            return
        }

        lastKeepaliveTime = now
        fallbackFrameCount += 1
        MirageLogger.capture("Fallback frame \(fallbackFrameCount): \(width)x\(height), contentRect=\(Int(contentRect.width))x\(Int(contentRect.height))")

        // Update timing to pace keepalive fallback frames
        lastDeliveredFrameTime = now

        // Create frame info - mark as keepalive so it won't be dropped by StreamContext's 0% dirty filter
        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect,
            dirtyRects: [],
            dirtyPercentage: 0.0,
            isKeepalive: true
        )

        onFrame(sampleBuffer, frameInfo)
    }

    /// Create a CMSampleBuffer from a CVPixelBuffer
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let format = formatDescription else {
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else {
            return nil
        }

        return sampleBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let captureTime = CFAbsoluteTimeGetCurrent()  // Timing: when SCK delivered the frame

        // NOTE: lastDeliveredFrameTime is updated ONLY for .complete frames (below)
        // This allows the watchdog to continue firing during drags when SCK only sends .idle frames

        // Check if we're resuming from fallback mode
        // Only request keyframe if fallback lasted long enough to cause decode issues
        fallbackLock.lock()
        if wasInFallbackMode {
            let fallbackDuration = CFAbsoluteTimeGetCurrent() - fallbackStartTime
            wasInFallbackMode = false

            // Only request keyframe for long fallbacks (>200ms)
            // Brief fallbacks don't cause decoder reference frame issues
            if fallbackDuration > keyframeThreshold {
                onKeyframeRequest()
                MirageLogger.capture("SCK resumed after long fallback (\(Int(fallbackDuration * 1000))ms) - scheduling keyframe")
            } else {
                MirageLogger.capture("SCK resumed after brief fallback (\(Int(fallbackDuration * 1000))ms) - no keyframe needed")
            }
        }
        fallbackLock.unlock()

        // DIAGNOSTIC: Track frame delivery gaps to detect drag/menu freeze
        if lastFrameTime > 0 {
            let gap = captureTime - lastFrameTime
            if gap > 0.1 {  // Log gaps > 100ms
                let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("FRAME GAP: \(gapMs)ms since last frame")
            }
            if gap > maxFrameGap {
                maxFrameGap = gap
                if maxFrameGap > 0.2 {  // Only log significant new records
                    let gapMs = (maxFrameGap * 1000).formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("NEW MAX FRAME GAP: \(gapMs)ms")
                }
            }
        }
        lastFrameTime = captureTime

        guard type == .screen else { return }

        // Validate the sample buffer
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Check SCFrameStatus - track all statuses for diagnostics
        var isIdleFrame = false
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRawValue = attachments[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRawValue) {

            // DIAGNOSTIC: Track status distribution
            statusCounts[statusRawValue, default: 0] += 1
            if captureTime - lastStatusLogTime > 2.0 {
                lastStatusLogTime = captureTime
                let statusNames = statusCounts.map { (key, count) in
                    let name: String
                    switch SCFrameStatus(rawValue: key) {
                    case .idle: name = "idle"
                    case .complete: name = "complete"
                    case .blank: name = "blank"
                    case .suspended: name = "suspended"
                    case .started: name = "started"
                    case .stopped: name = "stopped"
                    default: name = "unknown(\(key))"
                    }
                    return "\(name):\(count)"
                }.joined(separator: ", ")
                MirageLogger.capture("Frame status distribution: [\(statusNames)]")
                statusCounts.removeAll()
            }

            // FIX A: Allow idle frames through instead of filtering them out
            // This fixes the drag/menu freeze issue - menus are separate windows,
            // so the captured window content doesn't change, but we still need
            // to send frames to maintain visual continuity. HEVC produces tiny
            // P-frames (~500 bytes) for unchanged content.
            if status == .idle {
                skippedIdleFrames += 1
                isIdleFrame = true
                // Don't return - let the frame through
            }

            // Skip blank/suspended frames - these indicate actual capture issues
            if status == .blank || status == .suspended {
                return
            }

            // Process both .complete and .idle frames now
            guard status == .complete || status == .idle else { return }

            // Update watchdog timer for any delivered frame so fallback only runs
            // when SCK stops delivering frames entirely.
            if status == .complete || status == .idle {
                lastDeliveredFrameTime = captureTime
            }
        }

        // Extract contentRect, scaleFactor, and dirtyRects from SCStreamFrameInfo attachments
        var contentRect = CGRect.zero
        var scaleFactor: CGFloat = 1.0
        var dirtyRects: [CGRect] = []

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first {

            // Extract scaleFactor first (contentRect is in 1x points, buffer may be 2x pixels)
            if let scale = attachments[.scaleFactor] as? CGFloat {
                scaleFactor = scale
            } else if let scale = attachments[.scaleFactor] as? Double {
                scaleFactor = CGFloat(scale)
            } else if let scale = attachments[.scaleFactor] as? NSNumber {
                scaleFactor = CGFloat(scale.doubleValue)
            }

            // Extract contentRect
            if let contentRectValue = attachments[.contentRect] {
                let contentRectDict = contentRectValue as! CFDictionary
                if let rect = CGRect(dictionaryRepresentation: contentRectDict) {
                    // Apply scaleFactor to convert from points to buffer pixels
                    contentRect = CGRect(
                        x: rect.origin.x * scaleFactor,
                        y: rect.origin.y * scaleFactor,
                        width: rect.width * scaleFactor,
                        height: rect.height * scaleFactor
                    )
                }
            }

            // Extract dirty rects - regions that changed since last frame
            if let dirtyRectsValue = attachments[.dirtyRects] as? [Any] {
                for rectValue in dirtyRectsValue {
                    // Cast to CFDictionary for CGRect initialization
                    let rectDict = rectValue as CFTypeRef
                    if CFGetTypeID(rectDict) == CFDictionaryGetTypeID(),
                       let rect = CGRect(dictionaryRepresentation: rectDict as! CFDictionary) {
                        // Apply scaleFactor to convert to buffer pixels
                        let scaledRect = CGRect(
                            x: rect.origin.x * scaleFactor,
                            y: rect.origin.y * scaleFactor,
                            width: rect.width * scaleFactor,
                            height: rect.height * scaleFactor
                        )
                        dirtyRects.append(scaledRect)
                    }
                }
            }
        }

        // Calculate dirty region statistics for logging
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let totalPixels = bufferWidth * bufferHeight

        // Clip dirty rects to buffer bounds (ScreenCaptureKit can report out-of-bounds rects after resolution changes)
        let clippedDirtyRects = dirtyRects.map { rect -> CGRect in
            let clippedX = max(0, min(rect.origin.x, CGFloat(bufferWidth)))
            let clippedY = max(0, min(rect.origin.y, CGFloat(bufferHeight)))
            let clippedWidth = min(rect.width, CGFloat(bufferWidth) - clippedX)
            let clippedHeight = min(rect.height, CGFloat(bufferHeight) - clippedY)
            return CGRect(x: clippedX, y: clippedY, width: max(0, clippedWidth), height: max(0, clippedHeight))
        }

        // Calculate dirty percentage from SCK's reported dirty rects (for diagnostics/telemetry)
        // Note: P-frames handle delta compression natively - this is informational only
        let dirtyArea = clippedDirtyRects.reduce(0) { $0 + Int($1.width * $1.height) }
        let dirtyPercentage = totalPixels > 0 ? min(100.0, (Float(dirtyArea) / Float(totalPixels)) * 100) : 0

        // Use clipped rects for the frame info
        let finalDirtyRects = clippedDirtyRects

        // Note: P-frames handle delta compression natively in HEVC - no need for
        // Metal-based dirty detection. The encoder only encodes changed pixels.

        // Track small change frames (less than 5% of screen changed)
        if dirtyPercentage > 0 && dirtyPercentage < 5 {
            smallChangeFrames += 1
        }

        // Fallback: if contentRect is zero/invalid, use full buffer dimensions
        if contentRect.isEmpty {
            contentRect = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
                height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            )
        }

        // Log frame dimensions periodically (first frame and every 10 seconds at 60fps)
        frameCount += 1
        if frameCount == 1 || frameCount % 600 == 0 {
            MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)")
        }

        // Create frame info with all capture metadata (using clipped rects)
        // Keyframe requests are now handled by StreamContext cadence, so don't flag here.
        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect,
            dirtyRects: finalDirtyRects,
            dirtyPercentage: dirtyPercentage
        )

        // Cache frame for re-sending during SCK pauses (menus, drags)
        // Only cache frames with content changes to avoid stale cache
        if dirtyPercentage > 0 {
            cacheFrame(pixelBuffer, contentRect: contentRect)
        }

        onFrame(sampleBuffer, frameInfo)
    }
}

/// Frame pacing controller for consistent frame timing
actor FramePacingController {
    private let targetFrameInterval: TimeInterval
    private var lastFrameTime: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedCount: UInt64 = 0

    private var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(targetFPS: Int) {
        self.targetFrameInterval = 1.0 / Double(targetFPS)
    }

    /// Check if a frame should be captured based on timing
    func shouldCaptureFrame() -> Bool {
        let now = mach_absolute_time()

        if lastFrameTime == 0 {
            lastFrameTime = now
            frameCount += 1
            return true
        }

        let elapsedNanos = (now - lastFrameTime) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0

        if elapsedSeconds >= targetFrameInterval * 0.95 {
            lastFrameTime = now
            frameCount += 1
            return true
        }

        return false
    }

    /// Mark a frame as dropped
    func markFrameDropped() {
        droppedCount += 1
    }

    /// Get statistics
    func getStatistics() -> (frames: UInt64, dropped: UInt64) {
        (frameCount, droppedCount)
    }
}

// MARK: - Dirty Region Detection

/// Detects the bounding rectangle of changed pixels between frames
/// Used for future partial-frame encoding optimization
final class DirtyRegionDetector: @unchecked Sendable {
    private var previousBuffer: CVPixelBuffer?
    private let blockSize: Int = 16  // Scan in 16x16 blocks for efficiency

    /// Result of dirty region detection
    struct DetectionResult {
        /// Bounding rectangle of all changed pixels (nil if no changes)
        let dirtyRect: CGRect?
        /// Percentage of frame that changed (0.0 - 1.0)
        let changePercentage: Float
        /// Whether the change is considered "small" (< 5% of frame)
        let isSmallChange: Bool
    }

    /// Detect dirty region by comparing current frame to previous
    /// Returns nil on first frame or if comparison not possible
    func detectDirtyRegion(currentBuffer: CVPixelBuffer) -> DetectionResult? {
        defer {
            // Store current buffer for next comparison
            previousBuffer = currentBuffer
        }

        guard let previous = previousBuffer else {
            return nil  // First frame, nothing to compare
        }

        // Lock both buffers
        CVPixelBufferLockBaseAddress(currentBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(currentBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }

        guard let currentBase = CVPixelBufferGetBaseAddress(currentBuffer),
              let previousBase = CVPixelBufferGetBaseAddress(previous) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(currentBuffer)
        let height = CVPixelBufferGetHeight(currentBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(currentBuffer)

        // Ensure dimensions match
        guard width == CVPixelBufferGetWidth(previous),
              height == CVPixelBufferGetHeight(previous) else {
            return DetectionResult(dirtyRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                                   changePercentage: 1.0,
                                   isSmallChange: false)
        }

        var minX = width, maxX = 0, minY = height, maxY = 0
        var changedBlocks = 0
        let totalBlocks = ((width + blockSize - 1) / blockSize) * ((height + blockSize - 1) / blockSize)

        // Scan in blocks for efficiency
        for blockY in stride(from: 0, to: height, by: blockSize) {
            for blockX in stride(from: 0, to: width, by: blockSize) {
                // Sample center of block
                let x = min(blockX + blockSize / 2, width - 1)
                let y = min(blockY + blockSize / 2, height - 1)
                let offset = y * bytesPerRow + x * 4

                let currentPixel = currentBase.load(fromByteOffset: offset, as: UInt32.self)
                let previousPixel = previousBase.load(fromByteOffset: offset, as: UInt32.self)

                if currentPixel != previousPixel {
                    changedBlocks += 1
                    minX = min(minX, blockX)
                    maxX = max(maxX, min(blockX + blockSize, width))
                    minY = min(minY, blockY)
                    maxY = max(maxY, min(blockY + blockSize, height))
                }
            }
        }

        let changePercentage = Float(changedBlocks) / Float(max(1, totalBlocks))

        if changedBlocks == 0 {
            return DetectionResult(dirtyRect: nil, changePercentage: 0, isSmallChange: true)
        }

        let dirtyRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let isSmallChange = changePercentage < 0.05  // Less than 5% changed

        return DetectionResult(dirtyRect: dirtyRect, changePercentage: changePercentage, isSmallChange: isSmallChange)
    }

    /// Reset the detector (e.g., after dimension change)
    func reset() {
        previousBuffer = nil
    }
}

#endif
