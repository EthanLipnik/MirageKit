//
//  WindowCaptureEngine+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine extensions.
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
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: config.displayID,
                window: config.window,
                application: config.application,
                display: config.display,
                outputScale: scale,
                resolution: config.resolution,
                sourceRect: config.sourceRect,
                destinationRect: config.destinationRect,
                showsCursor: config.showsCursor,
                audioChannelCount: config.audioChannelCount,
                includedWindows: config.includedWindows,
                excludedWindows: config.excludedWindows
            )
        }

        // Don't update if dimensions haven't actually changed
        guard newWidth != currentWidth || newHeight != currentHeight else { return }

        // Clear cached fallback frame to prevent stale data during resize
        streamOutput?.clearCache()

        MirageLogger
            .capture(
                "Updating dimensions from \(currentWidth)x\(currentHeight) to \(newWidth)x\(newHeight) (scale: \(currentScaleFactor), outputScale: \(scale))"
            )

        currentWidth = newWidth
        currentHeight = newHeight

        // Create new stream configuration with updated dimensions
        let streamConfig = SCStreamConfiguration()
        streamConfig.captureResolution = .best
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        // Update the stream configuration
        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        MirageLogger.capture("Stream configuration updated to \(newWidth)x\(newHeight)")
    }

    func updateResolution(width: Int, height: Int) async throws {
        guard isCapturing, let stream else { return }

        // Don't update if dimensions haven't actually changed
        guard width != currentWidth || height != currentHeight else { return }

        // Clear cached fallback frame to prevent stale data during resize
        // This avoids sending old-resolution frames during SCK pause after config update
        streamOutput?.clearCache()

        MirageLogger
            .capture(
                "Updating resolution to client-requested \(width)x\(height) (was \(currentWidth)x\(currentHeight))"
            )

        currentWidth = width
        currentHeight = height
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: config.displayID,
                window: config.window,
                application: config.application,
                display: config.display,
                outputScale: config.outputScale,
                resolution: CGSize(width: width, height: height),
                sourceRect: config.sourceRect,
                destinationRect: config.destinationRect,
                showsCursor: config.showsCursor,
                audioChannelCount: config.audioChannelCount,
                includedWindows: config.includedWindows,
                excludedWindows: config.excludedWindows
            )
        }

        // Create new stream configuration with client's exact pixel dimensions
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth
        if let sourceRect = captureSessionConfig?.sourceRect, !sourceRect.isEmpty {
            streamConfig.sourceRect = sourceRect
        }

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        MirageLogger.capture("Resolution updated to client dimensions: \(width)x\(height)")
    }

    func updateCaptureDisplay(_ newDisplay: SCDisplay, resolution: CGSize, sourceRect: CGRect? = nil) async throws {
        guard isCapturing, let stream else { return }

        // Clear cached fallback frame when switching displays
        streamOutput?.clearCache()

        let newWidth = Int(resolution.width)
        let newHeight = Int(resolution.height)

        MirageLogger.capture("Switching capture to new display \(newDisplay.displayID) at \(newWidth)x\(newHeight)")
        updateDisplayRefreshRate(for: newDisplay.displayID)

        // Update dimensions
        currentWidth = newWidth
        currentHeight = newHeight
        displayUsesExplicitResolution = true
        var excludedWindows: [SCWindow] = []
        var resolvedSourceRect: CGRect? = sourceRect
        if let config = captureSessionConfig {
            resolvedSourceRect = sourceRect ?? config.sourceRect
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: newDisplay.displayID,
                window: config.window,
                application: config.application,
                display: newDisplay,
                outputScale: config.outputScale,
                resolution: resolution,
                sourceRect: resolvedSourceRect,
                destinationRect: config.destinationRect,
                showsCursor: config.showsCursor,
                audioChannelCount: config.audioChannelCount,
                includedWindows: config.includedWindows,
                excludedWindows: config.excludedWindows
            )
            excludedWindows = config.excludedWindows
        }

        // Create new filter for the new display
        let includedWindows = captureSessionConfig?.includedWindows ?? []
        let newFilter = Self.resolvedDisplayFilter(
            display: newDisplay,
            includedWindows: includedWindows,
            excludedWindows: excludedWindows
        )
        contentFilter = newFilter

        // Create configuration for the new display
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: resolvedSourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        // Apply both filter and configuration updates
        try await stream.updateContentFilter(newFilter)
        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)

        let captureRate = effectiveCaptureRate()
        let stallPolicy = resolvedStallPolicy(
            windowID: captureSessionConfig?.windowID ?? 0,
            frameRate: captureRate,
            captureMode: .display
        )
        activeStallPolicy = stallPolicy
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            targetFrameRate: currentFrameRate
        )

        MirageLogger.capture("Capture switched to display \(newDisplay.displayID) at \(newWidth)x\(newHeight)")
    }

    func updateExcludedWindows(_ windows: [SCWindow]) async throws {
        guard isCapturing, let stream, captureMode == .display else { return }

        let newIDs = Set(windows.map(\.windowID))
        let currentIDs = Set(excludedWindows.map(\.windowID))
        guard newIDs != currentIDs else { return }

        excludedWindows = windows
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: config.displayID,
                window: config.window,
                application: config.application,
                display: config.display,
                outputScale: config.outputScale,
                resolution: config.resolution,
                sourceRect: config.sourceRect,
                destinationRect: config.destinationRect,
                showsCursor: config.showsCursor,
                audioChannelCount: config.audioChannelCount,
                includedWindows: config.includedWindows,
                excludedWindows: windows
            )
        }

        guard let display = captureSessionConfig?.display else { return }
        let includedWindows = captureSessionConfig?.includedWindows ?? []
        let newFilter = Self.resolvedDisplayFilter(
            display: display,
            includedWindows: includedWindows,
            excludedWindows: windows
        )
        contentFilter = newFilter
        try await stream.updateContentFilter(newFilter)
        MirageLogger.capture("Updated display capture exclusions (\(windows.count) windows)")
    }

    func updateDisplayCaptureLayout(
        display: SCDisplay? = nil,
        sourceRect: CGRect? = nil,
        destinationRect: CGRect? = nil,
        contentWindowID: WindowID? = nil,
        includedWindows: [SCWindow]
    ) async throws {
        guard isCapturing, let stream, captureMode == .display else { return }
        guard let existingConfig = captureSessionConfig else { return }

        let resolvedDisplay = display ?? existingConfig.display
        let resolvedSourceRect = sourceRect ?? existingConfig.sourceRect
        let resolvedDestinationRect = destinationRect ?? existingConfig.destinationRect
        let resolvedContentWindowID = contentWindowID ?? existingConfig.windowID
        let includedWindowIDs = Set(includedWindows.map(\.windowID))
        let existingWindowIDs = Set(existingConfig.includedWindows.map(\.windowID))
        let filterChanged = resolvedDisplay.displayID != existingConfig.displayID || includedWindowIDs != existingWindowIDs
        let sourceRectChanged = resolvedSourceRect != existingConfig.sourceRect
        let destinationRectChanged = resolvedDestinationRect != existingConfig.destinationRect
        let contentWindowChanged = resolvedContentWindowID != existingConfig.windowID
        guard filterChanged || sourceRectChanged || destinationRectChanged || contentWindowChanged else {
            return
        }

        captureSessionConfig = CaptureSessionConfiguration(
            windowID: resolvedContentWindowID,
            applicationPID: existingConfig.applicationPID,
            displayID: resolvedDisplay.displayID,
            window: existingConfig.window,
            application: existingConfig.application,
            display: resolvedDisplay,
            outputScale: existingConfig.outputScale,
            resolution: existingConfig.resolution,
            sourceRect: resolvedSourceRect,
            destinationRect: resolvedDestinationRect,
            showsCursor: existingConfig.showsCursor,
            audioChannelCount: existingConfig.audioChannelCount,
            includedWindows: includedWindows,
            excludedWindows: existingConfig.excludedWindows
        )

        let newFilter = Self.resolvedDisplayFilter(
            display: resolvedDisplay,
            includedWindows: includedWindows,
            excludedWindows: existingConfig.excludedWindows
        )
        contentFilter = newFilter

        let streamConfig = SCStreamConfiguration()
        applyResolutionSettings(to: streamConfig)
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = existingConfig.showsCursor
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: resolvedSourceRect,
            destinationRect: resolvedDestinationRect
        )

        if filterChanged {
            try await stream.updateContentFilter(newFilter)
        }
        try await stream.updateConfiguration(streamConfig)
        let resolvedWindowID = CGWindowID(resolvedContentWindowID ?? 0)
        streamOutput?.updateWindowID(resolvedWindowID)
        let captureRate = effectiveCaptureRate()
        let stallPolicy = resolvedStallPolicy(
            windowID: resolvedWindowID,
            frameRate: captureRate,
            captureMode: .display
        )
        activeStallPolicy = stallPolicy
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            targetFrameRate: currentFrameRate
        )
        let includedWindowList = includedWindows.map(\.windowID)
        let filterMode = includedWindowList.isEmpty ? "fullDisplay" : "includedWindows"
        MirageLogger.capture(
            "Updated display capture layout for display \(resolvedDisplay.displayID), sourceRect=\(String(describing: resolvedSourceRect)), destinationRect=\(String(describing: resolvedDestinationRect)), filter=\(filterMode), includedWindows=\(includedWindowList)"
        )
    }

    func updateFrameRate(_ fps: Int) async throws {
        guard isCapturing, let stream else { return }

        MirageLogger.capture("Updating frame rate to \(fps) fps")
        currentFrameRate = fps

        // Create new stream configuration with updated frame rate
        let streamConfig = SCStreamConfiguration()
        applyResolutionSettings(to: streamConfig)
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        let captureRate = effectiveCaptureRate()
        let resolvedWindowID = captureSessionConfig?.windowID ?? 0
        let mode = captureMode ?? .window
        let stallPolicy = resolvedStallPolicy(
            windowID: resolvedWindowID,
            frameRate: captureRate,
            captureMode: mode
        )
        activeStallPolicy = stallPolicy
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            targetFrameRate: currentFrameRate
        )
        MirageLogger.capture("Frame rate updated to \(fps) fps")
    }

    func updateShowsCursor(_ showsCursor: Bool) async throws {
        if captureSessionConfig?.showsCursor == showsCursor { return }

        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: config.displayID,
                window: config.window,
                application: config.application,
                display: config.display,
                outputScale: config.outputScale,
                resolution: config.resolution,
                sourceRect: config.sourceRect,
                destinationRect: config.destinationRect,
                showsCursor: showsCursor,
                audioChannelCount: config.audioChannelCount,
                includedWindows: config.includedWindows,
                excludedWindows: config.excludedWindows
            )
        }

        guard isCapturing, let stream else { return }

        let streamConfig = SCStreamConfiguration()
        applyResolutionSettings(to: streamConfig)
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = showsCursor
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        MirageLogger.capture("Capture cursor visibility updated: showsCursor=\(showsCursor)")
    }

    func getCurrentDimensions() -> (width: Int, height: Int) {
        (currentWidth, currentHeight)
    }

    func updateConfiguration(_ newConfiguration: MirageEncoderConfiguration) async throws {
        configuration = newConfiguration
        guard isCapturing, let stream else { return }

        let streamConfig = SCStreamConfiguration()
        applyResolutionSettings(to: streamConfig)
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = captureColorSpaceName
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth
        Self.applyCaptureGeometry(
            to: streamConfig,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        let captureRate = effectiveCaptureRate()
        let resolvedWindowID = captureSessionConfig?.windowID ?? 0
        let mode = captureMode ?? .window
        let stallPolicy = resolvedStallPolicy(
            windowID: resolvedWindowID,
            frameRate: captureRate,
            captureMode: mode
        )
        activeStallPolicy = stallPolicy
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            softStallThreshold: stallPolicy.softStallThreshold,
            hardRestartThreshold: stallPolicy.hardRestartThreshold,
            targetFrameRate: currentFrameRate
        )
        MirageLogger
            .capture(
                "Capture configuration updated: pixelFormat=\(configuration.pixelFormat.displayName), " +
                    "color=\(configuration.colorSpace.displayName), queue=\(captureQueueDepth)"
            )
    }

    /// Apply resolution settings to a stream configuration.
    /// Window capture always uses `.best` with explicit dimensions.
    /// Display capture uses explicit dimensions only when an override resolution was provided.
    func applyResolutionSettings(to streamConfig: SCStreamConfiguration) {
        switch captureMode {
        case .window:
            streamConfig.captureResolution = .best
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        case .display:
            if displayUsesExplicitResolution {
                streamConfig.width = currentWidth
                streamConfig.height = currentHeight
            } else {
                streamConfig.captureResolution = .best
            }
        case nil:
            streamConfig.captureResolution = .best
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }
    }
}

#endif
