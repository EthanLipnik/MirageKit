//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Display capture on a shared virtual display.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func updateWindowCaptureVirtualDisplayState(_ snapshot: SharedVirtualDisplayManager.DisplaySnapshot?) {
        guard let snapshot else {
            virtualDisplayVisibleBounds = .zero
            virtualDisplayCaptureSourceRect = .zero
            virtualDisplayCapturePresentationRect = .zero
            return
        }

        let scaleFactor = max(1.0, snapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: snapshot.resolution,
            scaleFactor: scaleFactor
        )
        var displayBounds = CGVirtualDisplayBridge.displayBounds(
            snapshot.displayID,
            knownResolution: logicalResolution
        )
        if displayBounds.isEmpty {
            displayBounds = CGRect(origin: .zero, size: logicalResolution)
        }
        var visibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            visibleBounds = displayBounds
        }

        virtualDisplayVisibleBounds = visibleBounds
        let captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        virtualDisplayCapturePresentationRect = visibleBounds
        virtualDisplayCaptureSourceRect = captureSourceRect.isEmpty
            ? CGRect(origin: .zero, size: displayBounds.size)
            : captureSourceRect
    }

    func resolveWindowCaptureDisplayWrapper(
        sourceDisplayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
        label: String
    )
    async throws -> SCDisplayWrapper {
        guard let mirroredDisplaySnapshot else { return sourceDisplayWrapper }
        if mirroredDisplaySnapshot.displayID == sourceDisplayWrapper.display.displayID {
            return sourceDisplayWrapper
        }
        return try await resolveSCDisplayWrapper(
            displayID: mirroredDisplaySnapshot.displayID,
            label: label
        )
    }

    /// Starts shared-display capture for an app-stream virtual display.
    ///
    /// Mirrored app streaming normalizes the host window onto the shared app-stream display,
    /// then captures that display with a display filter limited to the selected window cluster.
    func startSharedDisplayWindowCapture(
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        mirroredDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        sizePreset: MirageDisplaySizePreset,
        clientLogicalSize: CGSize,
        sendPacketWithMetadata: @escaping StreamPacketSender.PacketMetadataSendHandler,
        onSendError: (@Sendable (Error) -> Void)? = nil
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let application = applicationWrapper.application
        isAppStream = true
        applicationProcessID = application.processID
        appStreamBundleIdentifier = application.bundleIdentifier.lowercased()
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        await setupPacketSender(
            sendPacketWithMetadata: sendPacketWithMetadata,
            onSendError: onSendError
        )

        virtualDisplayContext = mirroredDisplaySnapshot
        updateWindowCaptureVirtualDisplayState(mirroredDisplaySnapshot)

        MirageLogger.stream(
            "Stream \(streamID) using shared app-stream display \(mirroredDisplaySnapshot.displayID) " +
                "(\(Int(mirroredDisplaySnapshot.resolution.width))x\(Int(mirroredDisplaySnapshot.resolution.height)) @\(mirroredDisplaySnapshot.scaleFactor)x)"
        )

        let scaleFactor = max(1.0, mirroredDisplaySnapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: mirroredDisplaySnapshot.resolution,
            scaleFactor: scaleFactor
        )
        let mirroredDisplayBounds = CGVirtualDisplayBridge.displayBounds(
            mirroredDisplaySnapshot.displayID,
            knownResolution: logicalResolution
        )
        let mirroredVisibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
            mirroredDisplaySnapshot.displayID,
            knownBounds: mirroredDisplayBounds
        )
        let effectiveMirroredVisibleBounds = mirroredVisibleBounds.isEmpty
            ? mirroredDisplayBounds
            : mirroredVisibleBounds.intersection(mirroredDisplayBounds)
        let sourceDisplayBounds = CGDisplayBounds(displayWrapper.display.displayID)
        let sourceVisibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
            displayWrapper.display.displayID,
            knownBounds: sourceDisplayBounds
        )
        let effectiveSourceVisibleBounds = sourceVisibleBounds.isEmpty
            ? sourceDisplayBounds
            : sourceVisibleBounds.intersection(sourceDisplayBounds)
        let placementBounds = Self.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: effectiveSourceVisibleBounds,
            mirroredVisibleBounds: effectiveMirroredVisibleBounds
        )
        let targetContentAspectRatio = Self.targetWindowAspectRatio(
            requestedLogicalSize: clientLogicalSize,
            sizePreset: sizePreset
        )
        let targetWindowFrame = Self.aspectFittedFrame(
            within: placementBounds,
            aspectRatio: targetContentAspectRatio
        )
        virtualDisplayVisibleBounds = placementBounds
        virtualDisplayCapturePresentationRect = targetWindowFrame
        virtualDisplayCaptureSourceRect = Self.sharedDisplayAppCaptureSourceRect(
            presentationRect: targetWindowFrame,
            displayBounds: mirroredDisplayBounds
        )
        let targetWindowSize = targetWindowFrame.size
        MirageLogger.stream(
            "Stream \(streamID) window target: \(Int(targetWindowSize.width))x\(Int(targetWindowSize.height)) " +
                "(client requested \(Int(clientLogicalSize.width))x\(Int(clientLogicalSize.height)), " +
                "placement visible \(Int(placementBounds.width))x\(Int(placementBounds.height)), " +
                "preset=\(sizePreset.displayName))"
        )

        _ = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "pre-prepare window capture"
        )
        let resolvedDisplayWrapper = try await resolveWindowCaptureDisplayWrapper(
            sourceDisplayWrapper: displayWrapper,
            mirroredDisplaySnapshot: mirroredDisplaySnapshot,
            label: "mirrored app capture display"
        )

        try await WindowSpaceManager.shared.prepareWindowForMirroredCapture(
            windowID,
            owner: WindowSpaceManager.WindowBindingOwner(
                streamID: streamID
            )
        )

        _ = await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: targetWindowSize,
            aspectRatio: targetContentAspectRatio,
            maxBounds: placementBounds.size,
            label: "startup"
        )
        await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)
        try await Task.sleep(for: .milliseconds(24))

        let settledWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "post-prepare window capture"
        )
        let settledWindowFrame = Self.queryWindowFrame(windowID)?.standardized ?? settledWindowWrapper.window.frame.standardized

        let captureTarget = streamTargetDimensions(windowFrame: settledWindowFrame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Shared-display app capture init")
        MirageLogger.stream(
            "Shared-display app capture init: latency=\(latencyMode.displayName), scale=\(streamScale), " +
                "encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
        )

        let captureLayout = try await resolveSharedDisplayAppCaptureLayout(
            primaryWindowID: windowID,
            primaryWindowWrapper: settledWindowWrapper,
            primaryWindowFrameOverride: settledWindowFrame,
            displayWrapper: resolvedDisplayWrapper,
            outputSize: outputSize,
            label: "shared-display app capture start"
        )
        lastWindowFrame = settledWindowFrame
        capturedWindowClusterWindowIDs = captureLayout.clusterWindowIDs
        virtualDisplayCapturePresentationRect = captureLayout.presentationRect
        virtualDisplayCaptureSourceRect = captureLayout.captureSourceRect
        currentContentRect = captureLayout.destinationRect

        try await createAndPreheatEncoder(
            streamKind: .window,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        await startEncoderWithSharedCallback(pinnedContentRect: nil, logPrefix: "Frame")

        let captureEngine = try await setupAndStartCaptureEngine(
            usesDisplayRefreshCadence: true
        )
        try await captureEngine.startDisplayCapture(
            display: resolvedDisplayWrapper.display,
            resolution: outputSize,
            sourceRect: captureLayout.captureSourceRect,
            destinationRect: captureLayout.destinationRect,
            contentWindowID: windowID,
            includedWindows: captureLayout.includedWindowWrappers.map(\.window),
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()

        MirageLogger.stream(
            "Started stream \(streamID) with shared-display app capture on display \(mirroredDisplaySnapshot.displayID) for window \(windowID) cluster=\(captureLayout.clusterWindowIDs)"
        )
    }

    /// Updates window size for a resolution change (no virtual display reconfiguration needed).
    func updateWindowCaptureResolution(
        newLogicalSize: CGSize,
        targetAspectRatioOverride: CGFloat? = nil,
        forceReconfigure: Bool = false
    ) async throws {
        guard isRunning, useVirtualDisplay else { return }
        let rollbackSnapshot = makeResizeRollbackSnapshot()

        let placementBounds = resolvedVirtualDisplayPlacementBounds(for: newLogicalSize)
        let maxBounds = placementBounds.size
        let requestedAspectRatio: CGFloat? = if let targetAspectRatioOverride,
                                                targetAspectRatioOverride.isFinite,
                                                targetAspectRatioOverride > 0 {
            targetAspectRatioOverride
        } else if newLogicalSize.width > 0, newLogicalSize.height > 0 {
            newLogicalSize.width / newLogicalSize.height
        } else {
            nil
        }
        let effectiveSize = Self.aspectFittedFrame(
            within: placementBounds,
            aspectRatio: requestedAspectRatio
        ).size

        let currentSize = lastWindowFrame.size
        let sizeChanged = abs(currentSize.width - effectiveSize.width) > 2 ||
            abs(currentSize.height - effectiveSize.height) > 2
        guard sizeChanged || forceReconfigure else {
            MirageLogger.stream(
                "Skipping window resize for stream \(streamID): size unchanged"
            )
            return
        }

        isResizing = true
        defer { isResizing = false }

        let previousWindowFrame = rollbackSnapshot.lastWindowFrame

        MirageLogger.stream(
            "Resizing window for stream \(streamID) to \(Int(effectiveSize.width))x\(Int(effectiveSize.height)) logical " +
                "(client requested \(Int(newLogicalSize.width))x\(Int(newLogicalSize.height)))"
        )

        // Iteratively resize the window to match target aspect ratio
        _ = await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: effectiveSize,
            aspectRatio: requestedAspectRatio,
            maxBounds: maxBounds,
            label: "resize"
        )
        await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)

        // Brief pause for the window to settle
        try await Task.sleep(for: .milliseconds(24))

        // Re-resolve the SCWindow and display for new capture
        let resolvedWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "window resize"
        )
        let windowFrame = Self.queryWindowFrame(windowID)?.standardized ?? resolvedWindowWrapper.window.frame.standardized
        do {
            let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
            baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
            streamScale = resolvedStreamScale(
                for: baseCaptureSize,
                requestedScale: requestedStreamScale,
                logLabel: "Resolution cap"
            )
            let outputSize = scaledOutputSize(for: baseCaptureSize)
            let scaledWidth = Int(outputSize.width)
            let scaledHeight = Int(outputSize.height)
            guard scaledWidth > 0, scaledHeight > 0 else {
                throw MirageError.protocolError("Invalid app/window resize output size")
            }

            currentContentRect = .zero
            dimensionToken &+= 1
            MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
            await packetSender?.bumpGeneration(reason: "app/window resize")
            await packetSender?.resetQueue(reason: "app/window resize")
            resetPipelineStateForReconfiguration(reason: "app/window resize")

            lastWindowFrame = windowFrame
            currentCaptureSize = outputSize
            currentEncodedSize = outputSize
            captureMode = .display
            updateQueueLimits()
            if let captureEngine {
                try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
            }
            try await refreshSharedDisplayAppCaptureLayout(
                primaryWindowWrapper: resolvedWindowWrapper,
                primaryWindowFrameOverride: windowFrame,
                label: "window resize"
            )
            if let encoder {
                try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
            }
            updateQueueLimits()
            await applyDerivedQuality(for: outputSize, logLabel: "Shared-display app resize")
            await encoder?.forceKeyframe()
            MirageLogger.stream(
                "Window resize updated shared-display capture for stream \(streamID): " +
                    "encoded \(scaledWidth)x\(scaledHeight), capture \(captureTarget.width)x\(captureTarget.height)"
            )
        } catch {
            var restoredWindowFrame = previousWindowFrame
            if !previousWindowFrame.isEmpty {
                let previousAspectRatio = previousWindowFrame.width > 0 && previousWindowFrame.height > 0
                    ? previousWindowFrame.width / previousWindowFrame.height
                    : nil
                _ = await iterativelyResizeWindow(
                    windowID: windowID,
                    targetSize: previousWindowFrame.size,
                    aspectRatio: previousAspectRatio,
                    maxBounds: maxBounds,
                    label: "rollback"
                )
                await WindowSpaceManager.shared.centerWindow(windowID, on: placementBounds)
                try await Task.sleep(for: .milliseconds(24))
                do {
                    let resolvedRollbackWindowWrapper = try await resolveSCWindowWrapper(
                        windowID: windowID,
                        label: "window resize rollback"
                    )
                    restoredWindowFrame = Self.queryWindowFrame(windowID)?.standardized ??
                        resolvedRollbackWindowWrapper.window.frame.standardized
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to resolve rollback window frame: ")
                }
            }
            do {
                try await rollbackResizeFailure(
                    rollbackSnapshot,
                    logLabel: "Window resize",
                    restoredWindowFrame: restoredWindowFrame
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Window resize rollback failed: ")
            }
            throw error
        }
    }

    // MARK: - Aspect-Fit Sizing

    private func resolvedVirtualDisplayPlacementBounds(for fallbackLogicalSize: CGSize) -> CGRect {
        if let virtualDisplayContext {
            let scale = max(1.0, virtualDisplayContext.scaleFactor)
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: virtualDisplayContext.resolution,
                scaleFactor: scale
            )
            let displayBounds = CGVirtualDisplayBridge.displayBounds(
                virtualDisplayContext.displayID,
                knownResolution: logicalResolution
            )
            let visibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
                virtualDisplayContext.displayID,
                knownBounds: displayBounds
            )
            let resolvedVisibleBounds = visibleBounds.isEmpty
                ? displayBounds
                : visibleBounds.intersection(displayBounds)
            if resolvedVisibleBounds.width > 0, resolvedVisibleBounds.height > 0 {
                return resolvedVisibleBounds
            }
        }

        if virtualDisplayVisibleBounds.width > 0, virtualDisplayVisibleBounds.height > 0 {
            return virtualDisplayVisibleBounds
        }

        return CGRect(origin: .zero, size: fallbackLogicalSize)
    }
}

#endif
