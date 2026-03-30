//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window capture on a shared virtual display.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    /// Starts window capture on the shared app-stream virtual display.
    ///
    /// The shared display provides a known-good Retina backing at a fixed resolution.
    /// The window is moved to that display, resized to match the client's requested
    /// logical size, and captured individually via `desktopIndependentWindow`.
    func startWithWindowCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientLogicalSize: CGSize,
        sizePreset: MirageDisplaySizePreset,
        sendPacket: @escaping @Sendable (Data) async throws -> Void,
        onSendError: (@Sendable (Error) -> Void)? = nil,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void
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
        trafficLightMaskGeometryCache = nil
        lastTrafficLightMaskLogTime = 0

        self.onContentBoundsChanged = onContentBoundsChanged
        self.onNewWindowDetected = onNewWindowDetected
        await setupPacketSender(sendPacket: sendPacket, onSendError: onSendError)

        // 1. Acquire the shared app-stream virtual display
        let colorSpace = encoderConfig.colorSpace
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate)
        let vdSnapshot = try await SharedVirtualDisplayManager.shared.acquireAppStreamDisplay(
            preset: sizePreset,
            refreshRate: refreshRate,
            colorSpace: colorSpace
        )
        virtualDisplayContext = vdSnapshot

        MirageLogger.stream(
            "Stream \(streamID) acquired shared app-stream display \(vdSnapshot.displayID) " +
            "(\(sizePreset.displayName), \(Int(vdSnapshot.resolution.width))x\(Int(vdSnapshot.resolution.height)) @\(vdSnapshot.scaleFactor)x)"
        )

        // 2. Compute window size and resolve visible bounds
        let scaleFactor = max(1.0, vdSnapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: vdSnapshot.resolution,
            scaleFactor: scaleFactor
        )
        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            vdSnapshot.displayID,
            knownResolution: logicalResolution
        )
        let visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            vdSnapshot.displayID,
            knownBounds: displayBounds
        )
        let effectiveVisibleBounds = visibleBounds.isEmpty ? displayBounds : visibleBounds.intersection(displayBounds)
        let targetWindowSize = Self.aspectFitSize(
            requested: clientLogicalSize,
            maxBounds: effectiveVisibleBounds.size
        )
        MirageLogger.stream(
            "Stream \(streamID) window target: \(Int(targetWindowSize.width))x\(Int(targetWindowSize.height)) " +
            "(client requested \(Int(clientLogicalSize.width))x\(Int(clientLogicalSize.height)), " +
            "display visible \(Int(effectiveVisibleBounds.width))x\(Int(effectiveVisibleBounds.height)))"
        )

        // 3. Resolve SCWindow BEFORE moving it to the virtual display.
        //    After the move, SCK may not immediately see the window in its new space,
        //    causing resolution failures for Electron apps (Discord, Slack, etc.).
        let resolvedWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "pre-move window capture"
        )
        let resolvedDisplayWrapper = try await resolveSCDisplayWrapper(
            displayID: vdSnapshot.displayID,
            label: "pre-move display"
        )

        // 4. Move window to the shared display's space.
        let clientAspectRatio = clientLogicalSize.width > 0 && clientLogicalSize.height > 0
            ? clientLogicalSize.width / clientLogicalSize.height
            : nil
        let windowPlacementBounds = CGRect(
            origin: effectiveVisibleBounds.origin,
            size: targetWindowSize
        )
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdSnapshot.spaceID,
            displayID: vdSnapshot.displayID,
            displayBounds: windowPlacementBounds,
            targetContentAspectRatio: clientAspectRatio,
            owner: WindowSpaceManager.WindowBindingOwner(
                streamID: streamID,
                windowID: windowID,
                displayID: vdSnapshot.displayID,
                generation: vdSnapshot.generation
            )
        )

        // 5. Iteratively resize window to match target aspect ratio
        await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: targetWindowSize,
            aspectRatio: clientAspectRatio,
            maxBounds: effectiveVisibleBounds.size,
            label: "startup"
        )

        let settledWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "post-resize window capture"
        )

        // 6. Configure capture dimensions from actual window frame
        let captureTarget = streamTargetDimensions(windowFrame: settledWindowWrapper.window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = settledWindowWrapper.window.frame
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Window capture init")
        MirageLogger.stream(
            "Window capture init: latency=\(latencyMode.displayName), scale=\(streamScale), " +
            "encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
        )

        // 6. Create encoder and start capture
        try await createAndPreheatEncoder(
            streamKind: .window,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        await startEncoderWithSharedCallback(pinnedContentRect: nil, logPrefix: "Frame")

        let captureEngine = await setupAndStartCaptureEngine(usesDisplayRefreshCadence: false)
        try await captureEngine.startCapture(
            window: settledWindowWrapper.window,
            application: applicationWrapper.application,
            display: resolvedDisplayWrapper.display,
            outputScale: streamScale,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()

        MirageLogger.stream(
            "Started stream \(streamID) with window capture on shared display \(vdSnapshot.displayID) for window \(windowID)"
        )
    }

    /// Updates window size for a resolution change (no virtual display reconfiguration needed).
    func updateWindowCaptureResolution(newLogicalSize: CGSize) async throws {
        guard isRunning, useVirtualDisplay else { return }

        let currentSize = baseCaptureSize
        let requestedPixels = CGSize(
            width: max(1, ceil(newLogicalSize.width * 2)),
            height: max(1, ceil(newLogicalSize.height * 2))
        )
        guard abs(currentSize.width - requestedPixels.width) > 4
            || abs(currentSize.height - requestedPixels.height) > 4 else {
            MirageLogger.stream(
                "Skipping window resize for stream \(streamID): size unchanged"
            )
            return
        }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero
        dimensionToken &+= 1
        advanceEpoch(reason: "window resize")
        await packetSender?.bumpGeneration(reason: "window resize")
        await packetSender?.resetQueue(reason: "window resize")
        resetPipelineStateForReconfiguration(reason: "window resize")

        // Aspect-fit the requested size into the virtual display's visible bounds
        let effectiveSize: CGSize
        let maxBounds: CGSize
        if let vdContext = virtualDisplayContext {
            let scale = max(1.0, vdContext.scaleFactor)
            let logicalRes = SharedVirtualDisplayManager.logicalResolution(
                for: vdContext.resolution, scaleFactor: scale
            )
            let dBounds = CGVirtualDisplayBridge.getDisplayBounds(
                vdContext.displayID, knownResolution: logicalRes
            )
            let vBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
                vdContext.displayID, knownBounds: dBounds
            )
            let visible = vBounds.isEmpty ? dBounds : vBounds.intersection(dBounds)
            maxBounds = visible.size
            effectiveSize = Self.aspectFitSize(requested: newLogicalSize, maxBounds: maxBounds)
        } else {
            maxBounds = newLogicalSize
            effectiveSize = newLogicalSize
        }

        let clientAspectRatio = newLogicalSize.width > 0 && newLogicalSize.height > 0
            ? newLogicalSize.width / newLogicalSize.height
            : nil

        MirageLogger.stream(
            "Resizing window for stream \(streamID) to \(Int(effectiveSize.width))x\(Int(effectiveSize.height)) logical " +
            "(client requested \(Int(newLogicalSize.width))x\(Int(newLogicalSize.height)))"
        )

        // Stop capture before resizing
        await captureEngine?.stopCapture()

        // Iteratively resize the window to match target aspect ratio
        await iterativelyResizeWindow(
            windowID: windowID,
            targetSize: effectiveSize,
            aspectRatio: clientAspectRatio,
            maxBounds: maxBounds,
            label: "resize"
        )

        // Brief pause for the window to settle
        try? await Task.sleep(for: .milliseconds(80))

        // Re-resolve the SCWindow and display for new capture
        let resolvedWindowWrapper = try await resolveSCWindowWrapper(
            windowID: windowID,
            label: "window resize"
        )
        let windowFrame = resolvedWindowWrapper.window.frame

        let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        lastWindowFrame = windowFrame
        updateQueueLimits()

        if let encoder {
            try await encoder.updateDimensions(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            try await encoder.reset()
            activePixelFormat = await encoder.getActivePixelFormat()
            MirageLogger.encoder(
                "Encoder updated to \(Int(outputSize.width))x\(Int(outputSize.height)) for window resize"
            )
        }

        await applyDerivedQuality(for: outputSize, logLabel: "Window resize")

        // Restart capture with the new window dimensions
        guard let vdContext = virtualDisplayContext else {
            MirageLogger.error(.stream, "No virtual display context during window resize for stream \(streamID)")
            return
        }
        let resolvedDisplayWrapper = try await resolveSCDisplayWrapper(
            displayID: vdContext.displayID,
            label: "window resize"
        )
        let newCaptureEngine = await setupAndStartCaptureEngine(usesDisplayRefreshCadence: false)
        try await newCaptureEngine.startCapture(
            window: resolvedWindowWrapper.window,
            application: resolvedWindowWrapper.window.owningApplication!,
            display: resolvedDisplayWrapper.display,
            outputScale: streamScale,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()
        await encoder?.forceKeyframe()

        MirageLogger.stream("Window resize complete for stream \(streamID)")
    }

    // MARK: - SCK Resolution Helpers

    // MARK: - Aspect-Fit Sizing

    /// Compute the largest size that fits `maxBounds` while preserving the aspect ratio of `requested`.
    static func aspectFitSize(requested: CGSize, maxBounds: CGSize) -> CGSize {
        let rW = requested.width
        let rH = requested.height
        guard rW > 0, rH > 0, maxBounds.width > 0, maxBounds.height > 0 else {
            return CGSize(width: max(200, maxBounds.width), height: max(200, maxBounds.height))
        }
        let fs: CGFloat = (rW <= maxBounds.width && rH <= maxBounds.height)
            ? 1.0
            : min(maxBounds.width / rW, maxBounds.height / rH)
        return CGSize(
            width: max(200, (rW * fs).rounded(.down)),
            height: max(200, (rH * fs).rounded(.down))
        )
    }

    /// Iteratively resize the window to match the target aspect ratio.
    /// Starts at `targetSize` and shrinks proportionally if the app rejects the size.
    /// Gives up after a few attempts — the window will be whatever the app accepted.
    private func iterativelyResizeWindow(
        windowID: WindowID,
        targetSize: CGSize,
        aspectRatio: CGFloat?,
        maxBounds: CGSize,
        label: String
    ) async {
        let ar = aspectRatio ?? (targetSize.width / max(1, targetSize.height))
        var candidateW = targetSize.width
        var candidateH = targetSize.height
        let maxAttempts = 4

        for attempt in 1 ... maxAttempts {
            let candidate = CGSize(
                width: max(200, candidateW.rounded(.down)),
                height: max(200, candidateH.rounded(.down))
            )
            await WindowSpaceManager.shared.resizeWindow(windowID, to: candidate)

            // Brief settle
            try? await Task.sleep(for: .milliseconds(30))

            // Check actual compositor size via CGWindowList
            let windowFrame = Self.queryWindowFrame(windowID)
            if let windowFrame {
                let actualW = windowFrame.width
                let actualH = windowFrame.height
                let actualAR = actualW / max(1, actualH)
                let arDelta = abs(actualAR - ar) / max(0.001, ar)

                if arDelta < 0.03 {
                    // Close enough — aspect ratio matches within 3%
                    MirageLogger.stream(
                        "Window \(windowID) accepted \(Int(actualW))x\(Int(actualH)) at attempt \(attempt) " +
                        "(target AR \(String(format: "%.3f", ar)), actual AR \(String(format: "%.3f", actualAR)), \(label))"
                    )
                    return
                }

                // App rejected our size — it may have a minimum constraint.
                // Shrink the limiting dimension while preserving aspect ratio.
                if attempt < maxAttempts {
                    // Use the app's actual height (which is the constrained axis) and compute width from AR
                    if actualH < candidate.height {
                        // Height was constrained — use it and compute width
                        candidateH = actualH
                        candidateW = min(maxBounds.width, actualH * ar)
                    } else if actualW < candidate.width {
                        // Width was constrained — use it and compute height
                        candidateW = actualW
                        candidateH = min(maxBounds.height, actualW / ar)
                    } else {
                        // Both accepted but AR doesn't match — scale down uniformly
                        candidateW *= 0.92
                        candidateH *= 0.92
                    }
                    MirageLogger.stream(
                        "Window \(windowID) AR mismatch at \(Int(actualW))x\(Int(actualH)) " +
                        "(target AR \(String(format: "%.3f", ar)), actual \(String(format: "%.3f", actualAR))), " +
                        "retrying \(Int(candidateW))x\(Int(candidateH)) (\(label), attempt \(attempt + 1))"
                    )
                }
            } else {
                return // Can't query window, bail
            }
        }
    }

    /// Query a window's frame via CGWindowList.
    private static func queryWindowFrame(_ windowID: WindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }

    // MARK: - SCK Resolution Helpers

    private func resolveSCWindowWrapper(
        windowID: WindowID,
        label: String,
        maxAttempts: Int = 10,
        initialDelayMs: Int = 100
    )
    async throws -> SCWindowWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCWindow \(windowID) on attempt \(attempt) (\(label))")
                }
                return SCWindowWrapper(window: window)
            }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(600, Int(Double(delayMs) * 1.5))
            } else {
                let windowDetails = content.windows.map { w in
                    "(\(w.windowID), \(w.owningApplication?.bundleIdentifier ?? "unknown"))"
                }
                MirageLogger.stream(
                    "Unable to resolve SCWindow \(windowID) after \(attempts) attempts (\(label)). " +
                    "Available windows (\(content.windows.count)): \(windowDetails)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCWindow \(windowID) for stream \(streamID) (\(label))")
    }

    private func resolveSCDisplayWrapper(
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCDisplay \(displayID) on attempt \(attempt) (\(label))")
                }
                return SCDisplayWrapper(display: display)
            }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            } else {
                let isOnline = CGDisplayIsOnline(displayID) != 0
                let available = content.displays.map(\.displayID)
                MirageLogger.stream(
                    "Unable to resolve SCDisplay \(displayID) after \(attempts) attempts (\(label)). " +
                    "CGDisplayIsOnline=\(isOnline), available SCK displays: \(available)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCDisplay \(displayID) for stream \(streamID) (\(label))")
    }
}

#endif
