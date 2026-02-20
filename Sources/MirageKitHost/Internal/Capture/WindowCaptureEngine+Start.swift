//
//  WindowCaptureEngine+Start.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine start/stop.
//

import CoreMedia
import CoreVideo
import Foundation
import os
import MirageKit

#if os(macOS)
import AppKit
import ScreenCaptureKit

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
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        onDimensionChange: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    )
        async throws {
        guard !isCapturing else { throw MirageError.protocolError("Already capturing") }
        restartGeneration &+= 1

        capturedFrameHandler = onFrame
        capturedAudioHandler = onAudio
        dimensionChangeHandler = onDimensionChange

        currentDisplayRefreshRate = nil
        updateDisplayRefreshRate(for: display.displayID)
        if let refreshRate = currentDisplayRefreshRate { MirageLogger.capture("Display mode refresh rate: \(refreshRate)") }

        // Create stream configuration
        let streamConfig = SCStreamConfiguration()

        // Calculate target dimensions based on window frame
        // Use known scale factor if provided (for virtual displays on headless Macs),
        // otherwise detect from NSScreen
        let target: StreamTargetDimensions = if let knownScale = knownScaleFactor {
            streamTargetDimensions(windowFrame: window.frame, scaleFactor: knownScale)
        } else {
            streamTargetDimensions(windowFrame: window.frame)
        }

        let clampedScale = max(0.1, min(1.0, outputScale))
        self.outputScale = clampedScale
        currentScaleFactor = target.hostScaleFactor * clampedScale
        currentWidth = Self.alignedEvenPixel(CGFloat(target.width) * clampedScale)
        currentHeight = Self.alignedEvenPixel(CGFloat(target.height) * clampedScale)
        captureMode = .window
        useExplicitCaptureDimensions = true
        captureSessionConfig = CaptureSessionConfiguration(
            windowID: WindowID(window.windowID),
            applicationPID: application.processID,
            displayID: display.displayID,
            window: window,
            application: application,
            display: display,
            knownScaleFactor: knownScaleFactor,
            outputScale: clampedScale,
            resolution: nil,
            showsCursor: false,
            excludedWindows: []
        )

        // CRITICAL: For virtual displays on headless Macs, do NOT use .best or .nominal
        // as they may capture at wrong resolution (1x instead of 2x).
        // Setting explicit width/height WITHOUT captureResolution lets SCK use our dimensions.
        // For real displays, .best correctly detects backing scale factor.
        useBestCaptureResolution = (knownScaleFactor == nil)
        if useBestCaptureResolution { streamConfig.captureResolution = .best }
        // When knownScaleFactor is set, we intentionally don't set captureResolution
        // to let our explicit width/height control the output resolution
        streamConfig.width = currentWidth
        streamConfig.height = currentHeight

        MirageLogger
            .capture(
                "Configuring capture: \(currentWidth)x\(currentHeight), scale=\(currentScaleFactor), outputScale=\(clampedScale), knownScale=\(String(describing: knownScaleFactor))"
            )

        // Frame rate
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()

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
        streamConfig.showsCursor = false // Don't capture cursor - iPad shows its own
        streamConfig.capturesAudio = onAudio != nil
        if onAudio != nil {
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }
        streamConfig.queueDepth = captureQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 { MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)") }
        let queueDepth = streamConfig.queueDepth
        let poolMinimumCount = bufferPoolMinimumCount
        MirageLogger
            .capture(
                "Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), pool=\(poolMinimumCount)"
            )

        // Use window-level capture for precise dimensions (captures just this window)
        // Note: This may not capture modal dialogs/sheets, but avoids black bars from app-level bounding box
        let filter = SCContentFilter(desktopIndependentWindow: window)
        contentFilter = filter

        let windowTitle = window.title ?? "untitled"
        MirageLogger
            .capture(
                "Starting capture at \(currentWidth)x\(currentHeight) (scale: \(currentScaleFactor)) for window: \(windowTitle)"
            )

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else { throw MirageError.protocolError("Failed to create stream") }

        // Create output handler with windowID for fallback capture during SCK pauses
        let captureRate = effectiveCaptureRate()
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onAudio: onAudio,
            onKeyframeRequest: { [weak self] reason in
                self?.enqueueKeyframeRequest(reason)
            },
            onCaptureStall: { [weak self] reason in
                self?.enqueueCaptureRestart(reason)
            },
            shouldDropFrame: admissionDropper,
            windowID: window.windowID,
            usesDetailedMetadata: true,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: captureRate),
            stallThreshold: stallThreshold(for: captureRate),
            expectedFrameRate: Double(captureRate),
            targetFrameRate: currentFrameRate,
            poolMinimumBufferCount: bufferPoolMinimumCount
        )
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
        )
        if onAudio != nil {
            try stream.addStreamOutput(
                streamOutput!,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.audio", qos: .utility)
            )
        }

        // Start capturing
        try await stream.startCapture()
        isCapturing = true
    }

    /// Stop capturing
    func stopCapture() async {
        await stopCapture(clearSessionState: true)
    }

    private func stopCapture(clearSessionState: Bool) async {
        if clearSessionState { restartGeneration &+= 1 }
        guard isCapturing else {
            if clearSessionState {
                stream = nil
                streamOutput = nil
                captureSessionConfig = nil
                captureMode = nil
                capturedFrameHandler = nil
                capturedAudioHandler = nil
                dimensionChangeHandler = nil
                isRestarting = false
                pendingKeyframeRequest = nil
                restartStreak = 0
                lastRestartAttemptTime = 0
            }
            return
        }

        isCapturing = false

        do {
            try await stream?.stopCapture()
        } catch {
            MirageLogger.error(.capture, "Error stopping capture: \(error)")
        }

        stream = nil
        streamOutput = nil
        if clearSessionState {
            captureSessionConfig = nil
            captureMode = nil
            capturedFrameHandler = nil
            capturedAudioHandler = nil
            dimensionChangeHandler = nil
            isRestarting = false
            pendingKeyframeRequest = nil
            restartStreak = 0
            lastRestartAttemptTime = 0
        }
    }

    func restartCapture(reason: String) async {
        guard !isRestarting else { return }
        guard let config = captureSessionConfig, let mode = captureMode else { return }
        guard isCapturing else { return }
        guard let onFrame = capturedFrameHandler else { return }
        let onAudio = capturedAudioHandler
        let onDimensionChange = dimensionChangeHandler ?? { _, _ in }
        let now = CFAbsoluteTimeGetCurrent()

        if restartStreak > 0,
           Self.shouldResetRestartStreak(
               now: now,
               lastRestartAttemptTime: lastRestartAttemptTime,
               resetWindow: restartStreakResetWindow
           ) {
            MirageLogger.capture("Capture restart streak reset after stable interval")
            restartStreak = 0
        }

        let requiredCooldown = Self.restartCooldown(
            for: max(1, restartStreak),
            base: restartCooldownBase,
            multiplier: restartBackoffMultiplier,
            cap: restartCooldownCap
        )
        if lastRestartAttemptTime > 0 {
            let elapsed = now - lastRestartAttemptTime
            if elapsed <= requiredCooldown {
                let remainingMs = Int(((requiredCooldown - elapsed) * 1000).rounded())
                MirageLogger
                    .capture(
                        "Capture restart suppressed (\(reason)); cooldown \(remainingMs)ms remaining (streak \(restartStreak))"
                    )
                return
            }
        }

        let restartGeneration = self.restartGeneration

        isRestarting = true
        defer { isRestarting = false }
        restartStreak += 1
        let activeRestartStreak = restartStreak
        lastRestartAttemptTime = now
        let shouldEscalateRecovery = Self.shouldEscalateRecovery(
            restartStreak: activeRestartStreak,
            threshold: hardRecoveryEscalationThreshold
        )
        let nextCooldown = Self.restartCooldown(
            for: activeRestartStreak,
            base: restartCooldownBase,
            multiplier: restartBackoffMultiplier,
            cap: restartCooldownCap
        )
        MirageLogger
            .capture(
                "Restarting capture (\(reason)); streak=\(activeRestartStreak), " +
                    "escalate=\(shouldEscalateRecovery), nextCooldown=\(Int((nextCooldown * 1000).rounded()))ms"
            )

        await stopCapture(clearSessionState: false)
        guard restartGeneration == self.restartGeneration else {
            MirageLogger.capture("Capture restart canceled (stream shutdown in progress)")
            return
        }

        let resolvedConfig = await resolveCaptureTargetsForRestart(config: config, mode: mode)
        captureSessionConfig = resolvedConfig
        guard restartGeneration == self.restartGeneration else {
            MirageLogger.capture("Capture restart canceled (stream shutdown in progress)")
            return
        }

        do {
            switch mode {
            case .window:
                guard let window = resolvedConfig.window, let application = resolvedConfig.application else {
                    MirageLogger.error(.capture, "Capture restart failed: missing window/application")
                    break
                }
                try await startCapture(
                    window: window,
                    application: application,
                    display: resolvedConfig.display,
                    knownScaleFactor: resolvedConfig.knownScaleFactor,
                    outputScale: resolvedConfig.outputScale,
                    onFrame: onFrame,
                    onAudio: onAudio,
                    onDimensionChange: onDimensionChange
                )
            case .display:
                try await startDisplayCapture(
                    display: resolvedConfig.display,
                    resolution: resolvedConfig.resolution,
                    excludedWindows: resolvedConfig.excludedWindows,
                    showsCursor: resolvedConfig.showsCursor,
                    onFrame: onFrame,
                    onAudio: onAudio,
                    onDimensionChange: onDimensionChange
                )
            }
            markCaptureRestartKeyframeRequested(
                restartStreak: activeRestartStreak,
                shouldEscalateRecovery: shouldEscalateRecovery
            )
        } catch {
            MirageLogger.error(.capture, "Capture restart failed: \(error)")
        }
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
        excludedWindows: [SCWindow] = [],
        showsCursor: Bool = true,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        onDimensionChange: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    )
        async throws {
        guard !isCapturing else { throw MirageError.protocolError("Already capturing") }
        restartGeneration &+= 1

        capturedFrameHandler = onFrame
        capturedAudioHandler = onAudio
        dimensionChangeHandler = onDimensionChange

        // Create stream configuration for display capture
        let streamConfig = SCStreamConfiguration()

        // Use display's native resolution or the explicit pixel override (for HiDPI virtual displays)
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        currentWidth = max(1, Int(captureResolution.width))
        currentHeight = max(1, Int(captureResolution.height))
        captureMode = .display
        captureSessionConfig = CaptureSessionConfiguration(
            windowID: nil,
            applicationPID: nil,
            displayID: display.displayID,
            window: nil,
            application: nil,
            display: display,
            knownScaleFactor: nil,
            outputScale: 1.0,
            resolution: resolution,
            showsCursor: showsCursor,
            excludedWindows: excludedWindows
        )
        self.excludedWindows = excludedWindows

        updateDisplayRefreshRate(for: display.displayID)
        if let refreshRate = currentDisplayRefreshRate { MirageLogger.capture("Display mode refresh rate: \(refreshRate)") }

        // Calculate scale factor: if resolution was explicitly provided (HiDPI override),
        // compare it to display's reported dimensions to determine the scale
        // For HiDPI virtual displays: resolution=2064x2752 (pixels), display.width/height=1032x1376 (points) ->
        // scale=2.0
        if let res = resolution, display.width > 0 { currentScaleFactor = res.width / CGFloat(display.width) } else {
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
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()

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
        streamConfig.capturesAudio = onAudio != nil
        if onAudio != nil {
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }
        streamConfig.queueDepth = captureQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 { MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)") }
        let queueDepth = streamConfig.queueDepth
        let poolMinimumCount = bufferPoolMinimumCount
        MirageLogger
            .capture(
                "Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), pool=\(poolMinimumCount)"
            )

        // Capture displayID before creating filter (for logging after)
        let capturedDisplayID = display.displayID

        // Create filter for the entire display
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        contentFilter = filter

        if useExplicitCaptureDimensions {
            MirageLogger
                .capture(
                    "Starting display capture at \(currentWidth)x\(currentHeight) for display \(capturedDisplayID)"
                )
        } else {
            MirageLogger
                .capture(
                    "Starting display capture with .best (no explicit dimensions) for display \(capturedDisplayID)"
                )
        }

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else { throw MirageError.protocolError("Failed to create display stream") }

        // Create output handler
        let captureRate = effectiveCaptureRate()
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onAudio: onAudio,
            onKeyframeRequest: { [weak self] reason in
                self?.enqueueKeyframeRequest(reason)
            },
            onCaptureStall: { [weak self] reason in
                self?.enqueueCaptureRestart(reason)
            },
            shouldDropFrame: admissionDropper,
            usesDetailedMetadata: false,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: captureRate),
            stallThreshold: stallThreshold(for: captureRate),
            expectedFrameRate: Double(captureRate),
            targetFrameRate: currentFrameRate,
            poolMinimumBufferCount: bufferPoolMinimumCount
        )
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
        )
        if onAudio != nil {
            try stream.addStreamOutput(
                streamOutput!,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.audio", qos: .utility)
            )
        }

        // Start capturing
        try await stream.startCapture()
        isCapturing = true

        MirageLogger.capture("Display capture started for display \(display.displayID)")
    }
}

#endif
