//
//  WindowCaptureEngine+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine extensions.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import CoreVideo
import Foundation
import os

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
        let newWidth = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(CGFloat(target.width) * scale)
        let newHeight = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(CGFloat(target.height) * scale)
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
        let streamConfig = makeStreamConfigurationForUpdate(
            width: newWidth,
            height: newHeight,
            useBestCaptureResolution: true,
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

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
        let streamConfig = makeStreamConfigurationForUpdate(
            width: width,
            height: height,
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: captureSessionConfig?.sourceRect
        )

        try await stream.updateConfiguration(streamConfig)
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

        // Create configuration for the new display
        let streamConfig = makeStreamConfigurationForUpdate(
            width: newWidth,
            height: newHeight,
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: resolvedSourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        // Apply both filter and configuration updates
        try await stream.updateContentFilter(newFilter)
        try await stream.updateConfiguration(streamConfig)

        let captureRate = minimumFrameIntervalRate
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

        let streamConfig = makeStreamConfigurationForUpdate(
            showsCursor: existingConfig.showsCursor,
            sourceRect: resolvedSourceRect,
            destinationRect: resolvedDestinationRect
        )

        if filterChanged {
            try await stream.updateContentFilter(newFilter)
        }
        try await stream.updateConfiguration(streamConfig)
        let resolvedWindowID = CGWindowID(resolvedContentWindowID ?? 0)
        streamOutput?.updateWindowID(resolvedWindowID)
        let captureRate = minimumFrameIntervalRate
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
        let filterMode = includedWindowList.isEmpty ? "displayFullFrame" : "displayIncludedWindows"
        MirageLogger.capture(
            "Updated display capture layout for display \(resolvedDisplay.displayID), sourceRect=\(String(describing: resolvedSourceRect)), destinationRect=\(String(describing: resolvedDestinationRect)), filter=\(filterMode), includedWindows=\(includedWindowList)"
        )
    }

    func updateFrameRate(_ fps: Int) async throws {
        guard isCapturing, let stream else { return }

        MirageLogger.capture("Updating frame rate to \(fps) fps")
        currentFrameRate = fps
        if fps < 120 {
            minimumFrameIntervalPolicy = .automatic
        }

        // Create new stream configuration with updated frame rate
        let streamConfig = makeStreamConfigurationForUpdate(
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        let captureRate = minimumFrameIntervalRate
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

    func updateMinimumFrameIntervalPolicy(
        _ policy: MinimumFrameIntervalPolicy,
        reason: String
    ) async throws {
        let previousPolicy = minimumFrameIntervalPolicy
        guard previousPolicy != policy else { return }

        minimumFrameIntervalPolicy = policy
        guard isCapturing, let stream else {
            MirageLogger.capture(
                "Capture frame interval policy updated while idle: \(previousPolicy.rawValue) -> \(policy.rawValue), reason=\(reason)"
            )
            return
        }

        let streamConfig = makeStreamConfigurationForUpdate(
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        do {
            try await stream.updateConfiguration(streamConfig)
        } catch {
            minimumFrameIntervalPolicy = previousPolicy
            throw error
        }

        let captureRate = minimumFrameIntervalRate
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
        MirageLogger.capture(
            "event=capture_cadence_policy_update mode=display targetFPS=\(currentFrameRate) " +
                "sckFPS=\(captureRate) nativeDisplayCadence=\(usesNativeRefreshMinimumFrameInterval) " +
                "policy=\(policy.rawValue) previous=\(previousPolicy.rawValue) reason=\(reason)"
        )
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

        let streamConfig = makeStreamConfigurationForUpdate(
            showsCursor: showsCursor,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        MirageLogger.capture("Capture cursor visibility updated: showsCursor=\(showsCursor)")
    }

    func updateConfiguration(_ newConfiguration: MirageEncoderConfiguration) async throws {
        configuration = newConfiguration
        guard isCapturing, let stream else { return }

        let streamConfig = makeStreamConfigurationForUpdate(
            showsCursor: captureSessionConfig?.showsCursor ?? false,
            sourceRect: captureSessionConfig?.sourceRect,
            destinationRect: captureSessionConfig?.destinationRect
        )

        try await stream.updateConfiguration(streamConfig)
        let captureRate = minimumFrameIntervalRate
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
                    "color=\(configuration.colorSpace.displayName), queue=\(sckQueueDepth)"
            )
    }

}

#endif
