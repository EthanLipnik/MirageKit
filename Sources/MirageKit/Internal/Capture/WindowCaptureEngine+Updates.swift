//
//  WindowCaptureEngine+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine extensions.
//

import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
            timescale: CMTimeScale(minimumFrameIntervalRate())
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
    func getCurrentDimensions() -> (width: Int, height: Int) {
        (currentWidth, currentHeight)
    }
    func updateConfiguration(_ newConfig: MirageEncoderConfiguration) async throws {
        // Would need to restart capture with new config
    }
}

#endif
