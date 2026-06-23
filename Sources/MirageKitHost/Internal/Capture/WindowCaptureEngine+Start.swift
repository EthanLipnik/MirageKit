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
    /// Starts ScreenCaptureKit capture for a single desktop-independent window.
    func startCapture(
        window: SCWindow,
        application: SCRunningApplication,
        display: SCDisplay,
        outputScale: CGFloat = 1.0,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        audioChannelCount: Int? = nil
    )
        async throws {
        guard !isCapturing else { throw MirageError.protocolError("Already capturing") }
        cancelScheduledCaptureRestart(reason: "new_capture_start")
        restartGeneration &+= 1

        capturedFrameHandler = onFrame
        capturedAudioHandler = onAudio
        let resolvedAudioChannelCount = resolvedAudioCaptureChannelCount(
            isAudioEnabled: onAudio != nil,
            requestedChannelCount: audioChannelCount
        )

        currentDisplayRefreshRate = nil
        updateDisplayRefreshRate(for: display.displayID)
        if let refreshRate = currentDisplayRefreshRate { MirageLogger.capture("Display mode refresh rate: \(refreshRate)") }

        // Create stream configuration
        let streamConfig = SCStreamConfiguration()

        // Calculate target dimensions based on window frame
        let target = streamTargetDimensions(windowFrame: window.frame)

        let clampedScale = max(0.1, min(1.0, outputScale))
        self.outputScale = clampedScale
        currentScaleFactor = target.hostScaleFactor * clampedScale
        currentWidth = MirageStreamGeometry.alignedEncodedDimension(CGFloat(target.width) * clampedScale)
        currentHeight = MirageStreamGeometry.alignedEncodedDimension(CGFloat(target.height) * clampedScale)
        captureMode = .window
        captureSessionConfig = CaptureSessionConfiguration(
            windowID: WindowID(window.windowID),
            applicationPID: application.processID,
            displayID: display.displayID,
            window: window,
            application: application,
            display: display,
            outputScale: clampedScale,
            resolution: nil,
            sourceRect: nil,
            showsCursor: false,
            audioChannelCount: resolvedAudioChannelCount,
            excludedWindows: []
        )

        streamConfig.captureResolution = .best
        streamConfig.width = currentWidth
        streamConfig.height = currentHeight

        MirageLogger
            .capture(
                "Configuring capture: \(currentWidth)x\(currentHeight), scale=\(currentScaleFactor), outputScale=\(clampedScale)"
            )

        // Frame rate
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval

        // Color and format - configured pixel format (P010, ARGB2101010, BGRA, NV12)
        streamConfig.pixelFormat = pixelFormatType
        switch configuration.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }

        // Capture settings
        streamConfig.showsCursor = false // Don't capture cursor - iPad shows its own
        applyAudioSettings(
            to: streamConfig,
            enabled: onAudio != nil,
            channelCount: resolvedAudioChannelCount
        )
        streamConfig.queueDepth = sckQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 { MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)") }
        let queueDepth = streamConfig.queueDepth
        MirageLogger
            .capture(
                "Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), handoff=zeroCopy"
            )

        // Use window-level capture for precise dimensions (captures just this window)
        // Note: This may not capture modal dialogs/sheets, but avoids black bars from app-level bounding box
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let windowTitle = window.title ?? "untitled"
        MirageLogger
            .capture(
                "Starting capture at \(currentWidth)x\(currentHeight) (scale: \(currentScaleFactor)) for window: \(windowTitle)"
            )

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else { throw MirageError.protocolError("Failed to create stream") }

        // Create output handler with windowID for fallback capture during SCK pauses
        let captureRate = minimumFrameIntervalRate
        let stallPolicy = resolvedStallPolicy(
            windowID: window.windowID,
            frameRate: captureRate,
            captureMode: .window
        )
        activeStallPolicy = stallPolicy
        MirageLogger
            .capture(
                "event=stall_policy mode=window softMs=\(Int((stallPolicy.softStallThreshold * 1000).rounded())) " +
                    "hardMs=\(Int((stallPolicy.hardRestartThreshold * 1000).rounded())) " +
                    "debounceMs=\(Int((stallPolicy.restartDebounce * 1000).rounded())) " +
                    "profile=\(capturePressureProfile.rawValue)"
            )
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onAudio: onAudio,
            onCaptureStall: { [weak self] signal in
                self?.enqueueCaptureStallSignal(signal)
            },
            shouldDropFrame: admissionDropper,
            windowID: window.windowID,
            usesDetailedMetadata: true,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            expectedFrameRate: Double(captureRate),
            targetFrameRate: currentFrameRate
        )
        guard let output = streamOutput else {
            throw MirageError.captureSetupFailed("streamOutput was not initialized")
        }

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
        )
        if onAudio != nil {
            try stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.audio", qos: .utility)
            )
        }
        isAudioCaptureConfigured = onAudio != nil

        // Start capturing
        MirageLogger.capture("event=stream_lifecycle phase=start_attempt mode=window")
        try await stream.startCapture()
        isCapturing = true
        MirageLogger.capture("event=stream_lifecycle phase=start_success mode=window")
    }

    /// Starts ScreenCaptureKit capture for a display or display-scoped window set.
    ///
    /// Login streaming captures the full display with the cursor visible. Desktop streaming can provide included or
    /// excluded windows, geometry mapping, and explicit HiDPI pixel dimensions while the client renders its own cursor.
    /// - Parameters:
    ///   - display: The display to capture
    ///   - resolution: Optional pixel resolution override (used for HiDPI virtual displays)
    ///   - contentWindowID: Optional originating window ID for window-oriented stall policy while using display capture.
    ///   - showsCursor: Whether to show cursor in captured frames (true for login, false for desktop streaming)
    ///   - onFrame: Callback for each captured frame
    func startDisplayCapture(
        display: SCDisplay,
        resolution: CGSize? = nil,
        sourceRect: CGRect? = nil,
        destinationRect: CGRect? = nil,
        contentWindowID: WindowID? = nil,
        includedWindows: [SCWindow] = [],
        excludedWindows: [SCWindow] = [],
        showsCursor: Bool = true,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        audioChannelCount: Int? = nil
    )
        async throws {
        guard !isCapturing else { throw MirageError.protocolError("Already capturing") }
        cancelScheduledCaptureRestart(reason: "new_capture_start")
        restartGeneration &+= 1

        capturedFrameHandler = onFrame
        capturedAudioHandler = onAudio
        let resolvedAudioChannelCount = resolvedAudioCaptureChannelCount(
            isAudioEnabled: onAudio != nil,
            requestedChannelCount: audioChannelCount
        )

        // Create stream configuration for display capture
        let streamConfig = SCStreamConfiguration()

        // Use display's native resolution or the explicit pixel override (for HiDPI virtual displays)
        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        currentWidth = max(1, Int(captureResolution.width))
        currentHeight = max(1, Int(captureResolution.height))
        captureMode = .display
        captureSessionConfig = CaptureSessionConfiguration(
            windowID: contentWindowID,
            applicationPID: nil,
            displayID: display.displayID,
            window: nil,
            application: nil,
            display: display,
            outputScale: 1.0,
            resolution: resolution,
            sourceRect: sourceRect,
            destinationRect: destinationRect,
            showsCursor: showsCursor,
            audioChannelCount: resolvedAudioChannelCount,
            includedWindows: includedWindows,
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

        // For explicit resolution overrides (HiDPI virtual displays), set width/height and skip .best.
        // Otherwise let SCK use .best to detect the backing scale factor automatically.
        displayUsesExplicitResolution = (resolution != nil)
        if displayUsesExplicitResolution {
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
            if currentScaleFactor > 1.0 {
                MirageLogger.capture("HiDPI capture: scale=\(currentScaleFactor), using explicit resolution")
            }
        } else {
            streamConfig.captureResolution = .best
            MirageLogger.capture("HiDPI capture: scale=\(currentScaleFactor), forcing captureResolution=.best")
        }
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: sourceRect,
            destinationRect: destinationRect
        )

        // Frame rate
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval
        let configuredCaptureRate = minimumFrameIntervalRate
        let displayRefreshText = currentDisplayRefreshRate
            .map { $0.formatted(.number.precision(.fractionLength(1))) }
            ?? "unknown"
        MirageLogger.capture(
            "event=capture_cadence_config mode=display targetFPS=\(currentFrameRate) " +
                "sckFPS=\(configuredCaptureRate) displayRefresh=\(displayRefreshText) " +
                "nativeDisplayCadence=\(usesNativeRefreshMinimumFrameInterval) " +
                "intervalPolicy=\(minimumFrameIntervalPolicy.rawValue)"
        )

        // Color and format
        streamConfig.pixelFormat = pixelFormatType
        switch configuration.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }

        // Capture settings - cursor visibility depends on use case:
        // - Login screen: show cursor (true) for user interaction
        // - Desktop streaming: hide cursor (false) - client renders its own
        streamConfig.showsCursor = showsCursor
        applyAudioSettings(
            to: streamConfig,
            enabled: onAudio != nil,
            channelCount: resolvedAudioChannelCount
        )
        streamConfig.queueDepth = sckQueueDepth
        if let override = configuration.captureQueueDepth, override > 0 { MirageLogger.capture("Using capture queue depth override: \(streamConfig.queueDepth)") }
        let queueDepth = streamConfig.queueDepth
        MirageLogger
            .capture(
                "Capture buffering: latency=\(latencyMode.displayName), queue=\(queueDepth), handoff=zeroCopy"
            )

        // Capture displayID before creating filter (for logging after)
        let capturedDisplayID = display.displayID

        // Create filter for the entire display
        let filter = Self.resolvedDisplayFilter(
            display: display,
            includedWindows: includedWindows,
            excludedWindows: excludedWindows
        )

        let includedWindowIDs = includedWindows.map(\.windowID)
        let filterMode = includedWindowIDs.isEmpty ? "displayFullFrame" : "displayIncludedWindows"
        if displayUsesExplicitResolution {
            MirageLogger
                .capture(
                    "Starting display capture at \(currentWidth)x\(currentHeight) for display \(capturedDisplayID), " +
                        "sourceRect=\(String(describing: sourceRect)), destinationRect=\(String(describing: destinationRect)), " +
                        "filter=\(filterMode), includedWindows=\(includedWindowIDs)"
                )
        } else {
            MirageLogger
                .capture(
                    "Starting display capture with .best (no explicit dimensions) for display \(capturedDisplayID), " +
                        "destinationRect=\(String(describing: destinationRect)), filter=\(filterMode), includedWindows=\(includedWindowIDs)"
                )
        }

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        guard let stream else { throw MirageError.protocolError("Failed to create display stream") }

        // Create output handler
        let captureRate = minimumFrameIntervalRate
        let resolvedWindowID: CGWindowID = contentWindowID.map { CGWindowID($0) } ?? 0
        let stallPolicy = resolvedStallPolicy(
            windowID: resolvedWindowID,
            frameRate: captureRate,
            captureMode: .display
        )
        activeStallPolicy = stallPolicy
        let softMs = Int((stallPolicy.softStallThreshold * 1000).rounded())
        let hardMs = Int((stallPolicy.hardRestartThreshold * 1000).rounded())
        let debounceMs = Int((stallPolicy.restartDebounce * 1000).rounded())
        MirageLogger.capture(
            "event=stall_policy mode=display softMs=\(softMs) hardMs=\(hardMs) debounceMs=\(debounceMs) profile=\(capturePressureProfile.rawValue)"
        )
        streamOutput = CaptureStreamOutput(
            onFrame: onFrame,
            onAudio: onAudio,
            onCaptureStall: { [weak self] signal in
                self?.enqueueCaptureStallSignal(signal)
            },
            shouldDropFrame: admissionDropper,
            windowID: resolvedWindowID,
            usesDetailedMetadata: false,
            tracksFrameStatus: true,
            frameGapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            expectedFrameRate: Double(captureRate),
            targetFrameRate: currentFrameRate
        )
        guard let output = streamOutput else {
            throw MirageError.captureSetupFailed("streamOutput was not initialized")
        }

        // Use a high-priority capture queue so SCK delivery doesn't contend with UI work
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.output", qos: .userInteractive)
        )
        if onAudio != nil {
            try stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.mirage.capture.audio", qos: .utility)
            )
        }
        isAudioCaptureConfigured = onAudio != nil

        // Start capturing
        MirageLogger.capture("event=stream_lifecycle phase=start_attempt mode=display")
        try await stream.startCapture()
        isCapturing = true
        MirageLogger.capture("event=stream_lifecycle phase=start_success mode=display")

        MirageLogger.capture("Display capture started for display \(display.displayID)")
    }

    /// Resolves the requested audio channel count to the range supported by the capture pipeline.
    func resolvedAudioCaptureChannelCount(
        isAudioEnabled: Bool,
        requestedChannelCount: Int?
    ) -> Int? {
        guard isAudioEnabled else { return nil }
        let requested = requestedChannelCount ?? MirageAudioChannelLayout.stereo.channelCount
        return min(max(requested, 1), 8)
    }
}

#endif
