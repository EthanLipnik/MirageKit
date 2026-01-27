//
//  WindowCaptureEngine+Start.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine start/stop.
//

import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

extension WindowCaptureEngine {
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

        currentDisplayRefreshRate = nil

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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
        let queueDepth = streamConfig.queueDepth
        let poolMinimumCount = bufferPoolMinimumCount
        MirageLogger.capture("Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), pool=\(poolMinimumCount)")

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
            pacingFrameRate: currentFrameRate,
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

        updateDisplayRefreshRate(for: display.displayID)
        if let refreshRate = currentDisplayRefreshRate {
            MirageLogger.capture("Display mode refresh rate: \(refreshRate)")
        }

        // Calculate scale factor: if resolution was explicitly provided (HiDPI override),
        // compare it to display's reported dimensions to determine the scale
        // For HiDPI virtual displays: resolution=2064x2752 (pixels), display.width/height=1032x1376 (points) -> scale=2.0
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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
        let queueDepth = streamConfig.queueDepth
        let poolMinimumCount = bufferPoolMinimumCount
        MirageLogger.capture("Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), pool=\(poolMinimumCount)")

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
            pacingFrameRate: currentFrameRate,
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
}

#endif
