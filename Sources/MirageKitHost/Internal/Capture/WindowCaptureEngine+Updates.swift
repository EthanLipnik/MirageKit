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
                knownScaleFactor: config.knownScaleFactor,
                outputScale: scale,
                resolution: config.resolution,
                showsCursor: config.showsCursor,
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
        if useBestCaptureResolution { streamConfig.captureResolution = .best }
        useExplicitCaptureDimensions = true
        if useExplicitCaptureDimensions {
            streamConfig.width = newWidth
            streamConfig.height = newHeight
        }
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

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
        useBestCaptureResolution = false
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: config.displayID,
                window: config.window,
                application: config.application,
                display: config.display,
                knownScaleFactor: config.knownScaleFactor,
                outputScale: config.outputScale,
                resolution: CGSize(width: width, height: height),
                showsCursor: config.showsCursor,
                excludedWindows: config.excludedWindows
            )
        }

        // Create new stream configuration with client's exact pixel dimensions
        let streamConfig = SCStreamConfiguration()
        useExplicitCaptureDimensions = true
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        MirageLogger.capture("Resolution updated to client dimensions: \(width)x\(height)")
    }

    func updateCaptureDisplay(_ newDisplay: SCDisplay, resolution: CGSize) async throws {
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
        useBestCaptureResolution = false
        var excludedWindows: [SCWindow] = []
        if let config = captureSessionConfig {
            captureSessionConfig = CaptureSessionConfiguration(
                windowID: config.windowID,
                applicationPID: config.applicationPID,
                displayID: newDisplay.displayID,
                window: config.window,
                application: config.application,
                display: newDisplay,
                knownScaleFactor: config.knownScaleFactor,
                outputScale: config.outputScale,
                resolution: resolution,
                showsCursor: config.showsCursor,
                excludedWindows: config.excludedWindows
            )
            excludedWindows = config.excludedWindows
        }

        // Create new filter for the new display
        let newFilter = SCContentFilter(display: newDisplay, excludingWindows: excludedWindows)
        contentFilter = newFilter

        // Create configuration for the new display
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution { streamConfig.captureResolution = .best }
        useExplicitCaptureDimensions = true
        streamConfig.width = newWidth
        streamConfig.height = newHeight
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

        // Apply both filter and configuration updates
        try await stream.updateContentFilter(newFilter)
        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)

        let captureRate = effectiveCaptureRate()
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            stallThreshold: stallThreshold(for: captureRate),
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
                knownScaleFactor: config.knownScaleFactor,
                outputScale: config.outputScale,
                resolution: config.resolution,
                showsCursor: config.showsCursor,
                excludedWindows: windows
            )
        }

        guard let display = captureSessionConfig?.display else { return }
        let newFilter = SCContentFilter(display: display, excludingWindows: windows)
        contentFilter = newFilter
        try await stream.updateContentFilter(newFilter)
        MirageLogger.capture("Updated display capture exclusions (\(windows.count) windows)")
    }

    func updateFrameRate(_ fps: Int) async throws {
        guard isCapturing, let stream else { return }

        MirageLogger.capture("Updating frame rate to \(fps) fps")
        currentFrameRate = fps

        // Create new stream configuration with updated frame rate
        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution { streamConfig.captureResolution = .best }
        if useExplicitCaptureDimensions {
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = false
        streamConfig.queueDepth = captureQueueDepth

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        let captureRate = effectiveCaptureRate()
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            stallThreshold: stallThreshold(for: captureRate),
            targetFrameRate: currentFrameRate
        )
        MirageLogger.capture("Frame rate updated to \(fps) fps")
    }

    func getCurrentDimensions() -> (width: Int, height: Int) {
        (currentWidth, currentHeight)
    }

    func updateConfiguration(_ newConfiguration: MirageEncoderConfiguration) async throws {
        configuration = newConfiguration
        guard isCapturing, let stream else { return }

        let streamConfig = SCStreamConfiguration()
        if useBestCaptureResolution { streamConfig.captureResolution = .best }
        if useExplicitCaptureDimensions {
            streamConfig.width = currentWidth
            streamConfig.height = currentHeight
        }
        streamConfig.minimumFrameInterval = resolvedMinimumFrameInterval()
        streamConfig.pixelFormat = pixelFormatType
        streamConfig.colorSpaceName = configuration.colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB
        streamConfig.showsCursor = captureSessionConfig?.showsCursor ?? false
        streamConfig.queueDepth = captureQueueDepth

        try await stream.updateConfiguration(streamConfig)
        streamOutput?.prepareBufferPool(width: currentWidth, height: currentHeight, pixelFormat: pixelFormatType)
        let captureRate = effectiveCaptureRate()
        streamOutput?.updateExpectations(
            frameRate: captureRate,
            gapThreshold: frameGapThreshold(for: captureRate),
            stallThreshold: stallThreshold(for: captureRate),
            targetFrameRate: currentFrameRate
        )
        MirageLogger
            .capture(
                "Capture configuration updated: pixelFormat=\(configuration.pixelFormat.displayName), " +
                    "color=\(configuration.colorSpace.displayName), queue=\(captureQueueDepth)"
            )
    }
}

#endif
