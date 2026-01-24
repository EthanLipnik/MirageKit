//
//  WindowCaptureEngine.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

actor WindowCaptureEngine {
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private let configuration: MirageEncoderConfiguration
    private var currentFrameRate: Int
    private var pendingKeyframeRequest = false
    private var isCapturing = false
    private var isRestarting = false
    private var capturedFrameHandler: (@Sendable (CapturedFrame) -> Void)?
    private var dimensionChangeHandler: (@Sendable (Int, Int) -> Void)?
    private var captureMode: CaptureMode?
    private var captureSessionConfig: CaptureSessionConfiguration?

    // Track current dimensions to detect changes
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentScaleFactor: CGFloat = 1.0
    private var outputScale: CGFloat = 1.0
    private var useBestCaptureResolution: Bool = true
    private var useExplicitCaptureDimensions: Bool = true
    private var contentFilter: SCContentFilter?
    private var lastRestartTime: CFAbsoluteTime = 0
    private let restartCooldown: CFAbsoluteTime = 3.0

    init(configuration: MirageEncoderConfiguration) {
        self.configuration = configuration
        self.currentFrameRate = configuration.targetFrameRate
    }

    private enum CaptureMode {
        case window
        case display
    }

    private struct CaptureSessionConfiguration {
        let window: SCWindow?
        let application: SCRunningApplication?
        let display: SCDisplay
        let knownScaleFactor: CGFloat?
        let outputScale: CGFloat
        let resolution: CGSize?
        let showsCursor: Bool
    }

    private var captureQueueDepth: Int {
        if let override = configuration.captureQueueDepth, override > 0 {
            return min(max(1, override), 16)
        }
        if currentFrameRate >= 120 {
            return 8
        }
        if currentFrameRate >= 60 {
            return 6
        }
        return 4
    }

    private var bufferPoolMinimumCount: Int {
        let extra = currentFrameRate >= 120 ? 4 : 3
        return max(6, captureQueueDepth + extra)
    }

    private func frameGapThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 {
            return 0.18
        }
        if frameRate >= 60 {
            return 0.30
        }
        if frameRate >= 30 {
            return 0.50
        }
        return 1.5
    }

    private func stallThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 {
            return 2.5
        }
        if frameRate >= 60 {
            return 2.0
        }
        if frameRate >= 30 {
            return 2.5
        }
        return 4.0
    }

    private var pixelFormatType: OSType {
        switch configuration.pixelFormat {
        case .p010:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgr10a2:
            return kCVPixelFormatType_ARGB2101010LEPacked
        case .bgra8:
            return kCVPixelFormatType_32BGRA
        case .nv12:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
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
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
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
        captureMode = .window
        useExplicitCaptureDimensions = true
        captureSessionConfig = CaptureSessionConfiguration(
            window: window,
            application: application,
            display: display,
            knownScaleFactor: knownScaleFactor,
            outputScale: clampedScale,
            resolution: nil,
            showsCursor: false
        )

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
            timescale: CMTimeScale(currentFrameRate)
        )

        // Color and format - configured pixel format (P010, ARGB2101010, BGRA, NV12)
        streamConfig.pixelFormat = pixelFormatType
        switch configuration.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }
        // TODO: HDR support - add .hdr case when EDR configuration is figured out

        // Capture settings
        streamConfig.showsCursor = false  // Don't capture cursor - iPad shows its own
        streamConfig.queueDepth = captureQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 {
            MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)")
        }

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
            onCaptureStall: { [weak self] reason in
                Task { await self?.restartCapture(reason: reason) }
            },
            windowID: window.windowID,
            usesDetailedMetadata: true,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: currentFrameRate),
            stallThreshold: stallThreshold(for: currentFrameRate),
            expectedFrameRate: Double(currentFrameRate),
            poolMinimumBufferCount: bufferPoolMinimumCount
        )

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
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

    private func restartCapture(reason: String) async {
        guard !isRestarting else { return }
        guard let config = captureSessionConfig, let mode = captureMode else { return }
        guard let onFrame = capturedFrameHandler else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRestartTime > restartCooldown else { return }

        isRestarting = true
        lastRestartTime = now
        MirageLogger.capture("Restarting capture (\(reason))")

        await stopCapture()

        do {
            switch mode {
            case .window:
                guard let window = config.window, let application = config.application else {
                    MirageLogger.error(.capture, "Capture restart failed: missing window/application")
                    break
                }
                try await startCapture(
                    window: window,
                    application: application,
                    display: config.display,
                    knownScaleFactor: config.knownScaleFactor,
                    outputScale: config.outputScale,
                    onFrame: onFrame,
                    onDimensionChange: dimensionChangeHandler ?? { _, _ in }
                )
            case .display:
                try await startDisplayCapture(
                    display: config.display,
                    resolution: config.resolution,
                    showsCursor: config.showsCursor,
                    onFrame: onFrame,
                    onDimensionChange: dimensionChangeHandler ?? { _, _ in }
                )
            }
            pendingKeyframeRequest = true
        } catch {
            MirageLogger.error(.capture, "Capture restart failed: \(error)")
        }

        isRestarting = false
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
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                window: config.window,
                application: config.application,
                display: config.display,
                knownScaleFactor: config.knownScaleFactor,
                outputScale: scale,
                resolution: config.resolution,
                showsCursor: config.showsCursor
            )
        }

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
        useExplicitCaptureDimensions = true
        if useExplicitCaptureDimensions {
            streamConfig.width = newWidth
            streamConfig.height = newHeight
        }
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(currentFrameRate)
        )
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

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
        useBestCaptureResolution = false
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                window: config.window,
                application: config.application,
                display: config.display,
                knownScaleFactor: config.knownScaleFactor,
                outputScale: config.outputScale,
                resolution: CGSize(width: width, height: height),
                showsCursor: config.showsCursor
            )
        }

        // Create new stream configuration with client's exact pixel dimensions
        let streamConfig = SCStreamConfiguration()
        useExplicitCaptureDimensions = true
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(currentFrameRate)
        )
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

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
        useBestCaptureResolution = false
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                window: config.window,
                application: config.application,
                display: newDisplay,
                knownScaleFactor: config.knownScaleFactor,
                outputScale: config.outputScale,
                resolution: resolution,
                showsCursor: config.showsCursor
            )
        }

        // Create new filter for the new display
        let newFilter = SCContentFilter(display: newDisplay, excludingWindows: [])
        self.contentFilter = newFilter

        // Create configuration for the new display
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        useExplicitCaptureDimensions = true
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(currentFrameRate)
        )
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

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
        currentFrameRate = fps

        // Create new stream configuration with updated frame rate
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
        }
        if useExplicitCaptureDimensions {
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(fps)
        )
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.updateExpectations(
            frameRate: fps,
            gapThreshold: frameGapThreshold(for: fps),
            stallThreshold: stallThreshold(for: fps)
        )
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
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
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
        captureMode = .display
        captureSessionConfig = CaptureSessionConfiguration(
            window: nil,
            application: nil,
            display: display,
            knownScaleFactor: nil,
            outputScale: 1.0,
            resolution: resolution,
            showsCursor: showsCursor
        )

        if let displayMode = CGDisplayCopyDisplayMode(display.displayID) {
            let refreshRate = displayMode.refreshRate
            MirageLogger.capture("Display mode refresh rate: \(refreshRate)")
        }

        // Calculate scale factor: if resolution was explicitly provided (HiDPI override),
        // compare it to display's reported dimensions to determine the scale
        // For HiDPI virtual displays: resolution=2064x2752 (pixels), display.width/height=1032x1376 (points) → scale=2.0
        if let res = resolution, display.width > 0 {
            currentScaleFactor = res.width / CGFloat(display.width)
        } else {
            currentScaleFactor = 1.0
        }

        // For explicit resolution overrides (virtual displays), rely on width/height and skip .best
        useBestCaptureResolution = (resolution == nil)
        useExplicitCaptureDimensions = (resolution != nil)
        if useBestCaptureResolution {
            streamConfig.captureResolution = .best
            MirageLogger.capture("HiDPI capture: scale=\(currentScaleFactor), forcing captureResolution=.best")
        } else if currentScaleFactor > 1.0 {
            MirageLogger.capture("HiDPI capture: scale=\(currentScaleFactor), using explicit resolution")
        }

        if useExplicitCaptureDimensions {
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }

        // Frame rate
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(currentFrameRate)
        )

        // Color and format
        streamConfig.pixelFormat = pixelFormatType
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
        streamConfig.queueDepth = captureQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 {
            MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)")
        }

        // Capture displayID before creating filter (for logging after)
        let capturedDisplayID = display.displayID

        // Create filter for the entire display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.contentFilter = filter

        if useExplicitCaptureDimensions {
            MirageLogger.capture("Starting display capture at \(currentWidth)x\(currentHeight) for display \(capturedDisplayID)")
        } else {
            MirageLogger.capture("Starting display capture with .best (no explicit dimensions) for display \(capturedDisplayID)")
        }

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else {
            throw MirageError.protocolError("Failed to create display stream")
        }

        // Create output handler
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onKeyframeRequest: { [weak self] in
                Task { await self?.markKeyframeRequested() }
            },
            onCaptureStall: { [weak self] reason in
                Task { await self?.restartCapture(reason: reason) }
            },
            usesDetailedMetadata: false,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: currentFrameRate),
            stallThreshold: stallThreshold(for: currentFrameRate),
            expectedFrameRate: Double(currentFrameRate),
            poolMinimumBufferCount: bufferPoolMinimumCount
        )

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
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

    private func handleFrame(_ frame: CapturedFrame) {
        capturedFrameHandler?(frame)
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
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onKeyframeRequest: @Sendable () -> Void
    private let onCaptureStall: @Sendable (String) -> Void
    private let usesDetailedMetadata: Bool
    private let tracksFrameStatus: Bool
    private var frameCount: UInt64 = 0
    private var skippedIdleFrames: UInt64 = 0

    // DIAGNOSTIC: Track all frame statuses to debug drag/menu freeze issue
    private var statusCounts: [Int: UInt64] = [:]
    private var lastStatusLogTime: CFAbsoluteTime = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var maxFrameGap: CFAbsoluteTime = 0
    private var lastFpsLogTime: CFAbsoluteTime = 0
    private var deliveredFrameCount: UInt64 = 0
    private var deliveredCompleteCount: UInt64 = 0
    private var deliveredIdleCount: UInt64 = 0
    private var stallSignaled: Bool = false
    private var lastStallTime: CFAbsoluteTime = 0
    private var lastContentRect: CGRect = .zero

    // Frame gap watchdog: when SCK stops delivering frames (during menus/drags),
    // mark fallback mode so resume can trigger a keyframe request
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.mirage.capture.watchdog", qos: .userInteractive)
    private var windowID: CGWindowID = 0
    private var lastDeliveredFrameTime: CFAbsoluteTime = 0
    private var frameGapThreshold: CFAbsoluteTime
    private var stallThreshold: CFAbsoluteTime
    private var expectedFrameRate: Double
    private let expectationLock = NSLock()

    private let poolMinimumBufferCount: Int
    private let frameCopier: CaptureFrameCopier?
    private var loggedCopyFallback = false
    private var poolDropCount: UInt64 = 0
    private var lastPoolLogTime: CFAbsoluteTime = 0
    private let poolLogLock = NSLock()

    // Track if we've been in fallback mode - when SCK resumes, we may need a keyframe
    // to prevent decode errors from reference frame discontinuity
    private var wasInFallbackMode: Bool = false
    private var fallbackStartTime: CFAbsoluteTime = 0  // When fallback mode started
    private let fallbackLock = NSLock()

    // Only request keyframe if fallback lasted longer than this threshold
    // Brief fallbacks (<200ms) don't need keyframes - they're just normal SCK latency
    private let keyframeThreshold: CFAbsoluteTime = 0.35

    init(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onKeyframeRequest: @escaping @Sendable () -> Void,
        onCaptureStall: @escaping @Sendable (String) -> Void = { _ in },
        windowID: CGWindowID = 0,
        usesDetailedMetadata: Bool = false,
        tracksFrameStatus: Bool = true,
        frameGapThreshold: CFAbsoluteTime = 0.100,
        stallThreshold: CFAbsoluteTime = 1.0,
        expectedFrameRate: Double = 0,
        poolMinimumBufferCount: Int = 6
    ) {
        self.onFrame = onFrame
        self.onKeyframeRequest = onKeyframeRequest
        self.onCaptureStall = onCaptureStall
        self.windowID = windowID
        self.usesDetailedMetadata = usesDetailedMetadata
        self.tracksFrameStatus = tracksFrameStatus
        self.frameGapThreshold = frameGapThreshold
        self.stallThreshold = stallThreshold
        self.expectedFrameRate = expectedFrameRate
        self.poolMinimumBufferCount = max(2, poolMinimumBufferCount)
        self.frameCopier = CaptureFrameCopier()
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
        let initialDelayMs = expectationLock.withLock { max(50, Int(frameGapThreshold * 1000)) }
        timer.schedule(deadline: .now() + .milliseconds(initialDelayMs), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.checkForFrameGap()
        }
        timer.resume()
        watchdogTimer = timer
        let thresholdMs = expectationLock.withLock { Int(frameGapThreshold * 1000) }
        MirageLogger.capture("Frame gap watchdog started (\(thresholdMs)ms threshold, 50ms check interval)")
    }

    func stopWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    func updateExpectations(frameRate: Int, gapThreshold: CFAbsoluteTime, stallThreshold: CFAbsoluteTime) {
        expectationLock.withLock {
            expectedFrameRate = Double(frameRate)
            frameGapThreshold = gapThreshold
            self.stallThreshold = stallThreshold
        }
        stallSignaled = false
        stopWatchdogTimer()
        startWatchdogTimer()
    }

    /// Reset fallback state (called during dimension changes)
    func clearCache() {
        fallbackLock.lock()
        wasInFallbackMode = false
        fallbackStartTime = 0
        fallbackLock.unlock()
        MirageLogger.capture("Reset fallback state for resize")
    }

    /// Check if SCK has stopped delivering frames and trigger fallback
    private func checkForFrameGap() {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastDeliveredFrameTime > 0 else { return }

        let gap = now - lastDeliveredFrameTime
        let (gapThreshold, stallLimit) = expectationLock.withLock {
            (frameGapThreshold, stallThreshold)
        }
        guard gap > gapThreshold else { return }

        // SCK has stopped delivering - mark fallback mode
        markFallbackModeForGap()

        if gap > stallLimit, !stallSignaled, now - lastStallTime > stallLimit {
            stallSignaled = true
            lastStallTime = now
            let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
            onCaptureStall("frame gap \(gapMs)ms")
        }
    }

    /// Mark fallback mode when SCK stops delivering frames.
    private func markFallbackModeForGap() {
        // Mark that we're in fallback mode and record start time
        fallbackLock.lock()
        if wasInFallbackMode {
            fallbackLock.unlock()
            return
        }
        fallbackStartTime = CFAbsoluteTimeGetCurrent()
        wasInFallbackMode = true
        fallbackLock.unlock()
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

        let diagnosticsEnabled = MirageLogger.isEnabled(.capture)

        if !tracksFrameStatus {
            lastDeliveredFrameTime = captureTime
            stallSignaled = false
            if diagnosticsEnabled {
                deliveredFrameCount += 1
                if lastFpsLogTime == 0 {
                    lastFpsLogTime = captureTime
                } else if captureTime - lastFpsLogTime > 2.0 {
                    let elapsed = captureTime - lastFpsLogTime
                    let fps = Double(deliveredFrameCount) / elapsed
                    let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("Capture fps: \(fpsText)")
                    deliveredFrameCount = 0
                    lastFpsLogTime = captureTime
                }
            }

            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            frameCount += 1
            if frameCount == 1 || frameCount % 600 == 0 {
                MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)")
            }

            let frameInfo = CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight)),
                dirtyPercentage: 100,
                isIdleFrame: false
            )
            emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo)
            return
        }

        // Check SCFrameStatus - track all statuses for diagnostics
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        var isIdleFrame = false
        var status: SCFrameStatus?
        if let attachments,
           let statusRawValue = attachments[.status] as? Int,
           let resolvedStatus = SCFrameStatus(rawValue: statusRawValue) {
            status = resolvedStatus

            // DIAGNOSTIC: Track status distribution
            if diagnosticsEnabled {
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
            }

            // Allow idle frames through instead of filtering them out.
            if resolvedStatus == .idle {
                skippedIdleFrames += 1
                isIdleFrame = true
            }

            // Skip blank/suspended frames - these indicate actual capture issues.
            if resolvedStatus == .blank || resolvedStatus == .suspended {
                return
            }
        }

        let effectiveStatus = status ?? .complete
        guard effectiveStatus == .complete || effectiveStatus == .idle else { return }
        if effectiveStatus == .idle {
            isIdleFrame = true
        }

        // Update watchdog timer for any delivered frame so fallback only runs
        // when SCK stops delivering frames entirely.
        lastDeliveredFrameTime = captureTime
        stallSignaled = false
        if diagnosticsEnabled {
            deliveredFrameCount += 1
            if effectiveStatus == .idle {
                deliveredIdleCount += 1
            } else {
                deliveredCompleteCount += 1
            }
            if lastFpsLogTime == 0 {
                lastFpsLogTime = captureTime
            } else if captureTime - lastFpsLogTime > 2.0 {
                let elapsed = captureTime - lastFpsLogTime
                let fps = Double(deliveredFrameCount) / elapsed
                let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("Capture fps: \(fpsText) (complete=\(deliveredCompleteCount), idle=\(deliveredIdleCount))")
                deliveredFrameCount = 0
                deliveredCompleteCount = 0
                deliveredIdleCount = 0
                lastFpsLogTime = captureTime
            }
        }

        // Extract contentRect when detailed metadata is enabled. For display capture,
        // fast-path to full-buffer rect to minimize per-frame work.
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        var contentRect = CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight))
        if usesDetailedMetadata,
           !isIdleFrame,
           let attachments,
           let contentRectValue = attachments[.contentRect] {
            let scaleFactor: CGFloat
            if let scale = attachments[.scaleFactor] as? CGFloat {
                scaleFactor = scale
            } else if let scale = attachments[.scaleFactor] as? Double {
                scaleFactor = CGFloat(scale)
            } else if let scale = attachments[.scaleFactor] as? NSNumber {
                scaleFactor = CGFloat(scale.doubleValue)
            } else {
                scaleFactor = 1.0
            }
            let contentRectDict = contentRectValue as! CFDictionary
            if let rect = CGRect(dictionaryRepresentation: contentRectDict) {
                contentRect = CGRect(
                    x: rect.origin.x * scaleFactor,
                    y: rect.origin.y * scaleFactor,
                    width: rect.width * scaleFactor,
                    height: rect.height * scaleFactor
                )
                lastContentRect = contentRect
            } else if !lastContentRect.isEmpty {
                contentRect = lastContentRect
            }
        } else if !lastContentRect.isEmpty {
            contentRect = lastContentRect
        }

        // Calculate dirty region statistics for diagnostics only.
        let totalPixels = bufferWidth * bufferHeight
        let dirtyPercentage: Float
        if isIdleFrame {
            dirtyPercentage = 0
        } else if totalPixels > 0 {
            dirtyPercentage = 100
        } else {
            dirtyPercentage = 0
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

        // Create frame info with minimal capture metadata
        // Keyframe requests are now handled by StreamContext cadence, so don't flag here.
        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect,
            dirtyPercentage: dirtyPercentage,
            isIdleFrame: isIdleFrame
        )

        emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo)
    }

    private func emitFrame(
        sampleBuffer: CMSampleBuffer,
        sourcePixelBuffer: CVPixelBuffer,
        frameInfo: CapturedFrameInfo
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let emitFrame: @Sendable (CVPixelBuffer) -> Void = { [onFrame] pixelBuffer in
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                info: frameInfo
            )
            onFrame(frame)
        }

        if let frameCopier {
            let inFlightLimit = expectedFrameRate >= 120 ? 3 : 2
            let scheduleResult = frameCopier.scheduleCopy(
                pixelBuffer: sourcePixelBuffer,
                minimumBufferCount: poolMinimumBufferCount,
                inFlightLimit: inFlightLimit
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .copied(let copiedBuffer):
                    emitFrame(copiedBuffer)
                case .poolExhausted:
                    self.logPoolDrop()
                case .unsupported:
                    self.logCopyFallback("Capture copy failed: dropping frame")
                }
            }

            switch scheduleResult {
            case .scheduled:
                return
            case .poolExhausted:
                logPoolDrop()
                return
            case .unsupported:
                logCopyFallback("Capture copy unsupported: dropping frame")
            }
        } else {
            logCopyFallback("Capture copy disabled: dropping frame")
        }
    }

    private func logPoolDrop() {
        poolLogLock.withLock {
            poolDropCount += 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastPoolLogTime == 0 || now - lastPoolLogTime > 2.0 {
                MirageLogger.capture("Capture pool exhausted: dropped \(poolDropCount) frames")
                poolDropCount = 0
                lastPoolLogTime = now
            }
        }
    }

    private func logCopyFallback(_ message: String) {
        poolLogLock.withLock {
            guard !loggedCopyFallback else { return }
            loggedCopyFallback = true
            MirageLogger.capture(message)
        }
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
