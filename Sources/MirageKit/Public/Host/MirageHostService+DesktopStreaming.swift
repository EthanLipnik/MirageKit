import Foundation
import Network

#if os(macOS)
import ScreenCaptureKit

// MARK: - Desktop Streaming

extension MirageHostService {
    /// Start streaming the full desktop (virtual display mirroring mode)
    /// This stops any active app/window streams for mutual exclusivity
    // TODO: HDR support - add hdr: Bool = false parameter when EDR configuration is figured out
    func startDesktopStream(
        to clientContext: ClientContext,
        displayResolution: CGSize,
        qualityPreset: MirageQualityPreset,
        keyFrameInterval: Int?,
        frameQuality: Float?,
        keyframeQuality: Float?,
        pixelFormat: MiragePixelFormat?,
        colorSpace: MirageColorSpace?,
        captureQueueDepth: Int?,
        minBitrate: Int?,
        maxBitrate: Int?,
        streamScale: CGFloat?,
        adaptiveScaleEnabled: Bool?,
        dataPort: UInt16?,
        captureSource: MirageDesktopCaptureSource?,
        targetFrameRate: Int? = nil
    ) async throws {
        // Check session state - must be active
        await refreshSessionStateIfNeeded()
        guard sessionState == .active else {
            MirageLogger.host("Rejecting desktop stream while session is \(sessionState)")
            throw MirageError.protocolError("Session is locked")
        }

        // Check if desktop stream is already active
        guard desktopStreamContext == nil else {
            MirageLogger.host("Desktop stream already active")
            return
        }

        MirageLogger.host("Starting desktop stream at \(Int(displayResolution.width))x\(Int(displayResolution.height))")

        // Stop all active app/window streams (mutual exclusivity)
        await stopAllStreamsForDesktopMode()

        // Configure encoder with quality preset and optional overrides
        var config = encoderConfig
        let presetFrameRate = targetFrameRate ?? 60
        let presetConfig = qualityPreset.encoderConfiguration(for: presetFrameRate)
        config.keyFrameInterval = presetConfig.keyFrameInterval
        config.frameQuality = presetConfig.frameQuality
        config.keyframeQuality = presetConfig.keyframeQuality
        config.pixelFormat = presetConfig.pixelFormat
        config.colorSpace = presetConfig.colorSpace
        config.minBitrate = presetConfig.minBitrate
        config.maxBitrate = presetConfig.maxBitrate

        config = config.withOverrides(
            keyFrameInterval: keyFrameInterval,
            frameQuality: frameQuality,
            keyframeQuality: keyframeQuality,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            captureQueueDepth: captureQueueDepth,
            minBitrate: minBitrate,
            maxBitrate: maxBitrate
        )

        if let targetFrameRate {
            config = config.withTargetFrameRate(targetFrameRate)
        }
        // TODO: HDR support - requires proper virtual display EDR configuration
        // if hdr {
        //     config.colorSpace = .hdr
        //     MirageLogger.host("Desktop stream HDR enabled (Rec. 2020 + PQ)")
        // }

        let selectedCaptureSource = captureSource ?? .virtualDisplay

        // Acquire virtual display at client's full requested resolution
        // The 5K cap is applied at the encoding layer, not the virtual display
        // Pass the target frame rate to enable 120Hz when appropriate
        let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
            .desktopStream,
            resolution: displayResolution,
            refreshRate: targetFrameRate ?? 60,
            colorSpace: config.colorSpace
        )

        let captureDisplay: SCDisplayWrapper
        switch selectedCaptureSource {
        case .mainDisplay:
            captureDisplay = try await findMainSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
        case .virtualDisplay:
            captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
        }
        let captureResolution = context.resolution

        guard let bounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() else {
            throw MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
        }
        desktopDisplayBounds = bounds
        desktopUsesVirtualDisplay = true

        // Set up display mirroring so main display mirrors virtual display
        // This makes the main display adopt the virtual display's resolution
        await setupDisplayMirroring(targetDisplayID: context.displayID)

        let streamID = nextStreamID
        nextStreamID += 1
        if selectedCaptureSource == .virtualDisplay,
           captureDisplay.display.displayID != context.displayID {
            MirageLogger.error(.host, "Desktop capture display mismatch: capture=\(captureDisplay.display.displayID), virtual=\(context.displayID)")
        }
        MirageLogger.host("Desktop capture source: \(selectedCaptureSource.displayName) (capture display \(captureDisplay.display.displayID), virtual \(context.displayID), color=\(config.colorSpace.displayName))")

        let effectiveScale = streamScale ?? 1.0

        let streamContext = StreamContext(
            streamID: streamID,
            windowID: 0,
            encoderConfig: config,
            qualityPreset: qualityPreset,
            streamScale: effectiveScale,
            maxPacketSize: networkConfig.maxPacketSize,
            additionalFrameFlags: [.desktopStream],
            adaptiveScaleEnabled: adaptiveScaleEnabled ?? true
        )
        let metricsClientID = clientContext.client.id
        await streamContext.setMetricsUpdateHandler { [weak self] metrics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let clientContext = self.findClientContext(clientID: metricsClientID) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    MirageLogger.error(.host, "Failed to send desktop stream metrics: \(error)")
                }
            }
        }
        await streamContext.setStreamScaleUpdateHandler { [weak self] streamID in
            Task { @MainActor [weak self] in
                await self?.sendStreamScaleUpdate(streamID: streamID)
            }
        }

        desktopStreamContext = streamContext
        desktopStreamID = streamID
        desktopStreamClientContext = clientContext
        streamsByID[streamID] = streamContext

        // Register for input handling
        // Use main display bounds for input coordinate translation since main display mirrors virtual
        // Input is injected at main display coordinates, not virtual display coordinates
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let desktopWindow = MirageWindow(
            id: 0,
            title: "Desktop",
            application: nil,
            frame: mainDisplayBounds,
            isOnScreen: true,
            windowLayer: 0
        )
        inputStreamCacheActor.set(streamID, window: desktopWindow, client: clientContext.client)

        // Enable power assertion
        await PowerAssertionManager.shared.enable()

        // Start streaming the display
        try await streamContext.startDesktopDisplay(
            displayWrapper: captureDisplay,
            resolution: captureResolution,
            onEncodedFrame: { [weak self] packetData, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.sendVideoPacketForStream(streamID, data: packetData)
                }
            }
        )

        // Get dimension token from stream context
        let dimensionToken = await streamContext.getDimensionToken()

        // Send confirmation to client
        let encodedDimensions = await streamContext.getEncodedDimensions()
        let targetFrameRate = await streamContext.getTargetFrameRate()
        let codec = await streamContext.getCodec()
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: targetFrameRate,
            codec: codec,
            displayCount: 1,
            dimensionToken: dimensionToken
        )
        try? await clientContext.send(.desktopStreamStarted, content: message)

        MirageLogger.host("Desktop stream started: streamID=\(streamID), resolution=\(encodedDimensions.width)x\(encodedDimensions.height)")
    }

    /// Stop the desktop stream
    func stopDesktopStream(reason: DesktopStreamStopReason = .clientRequested) async {
        guard let streamID = desktopStreamID else { return }

        MirageLogger.host("Stopping desktop stream: streamID=\(streamID), reason=\(reason)")

        if let context = desktopStreamContext {
            await context.stop()
        }

        if desktopUsesVirtualDisplay, let displayID = await SharedVirtualDisplayManager.shared.getDisplayID() {
            await disableDisplayMirroring(displayID: displayID)
        }

        if let clientContext = desktopStreamClientContext {
            let message = DesktopStreamStoppedMessage(streamID: streamID, reason: reason)
            try? await clientContext.send(.desktopStreamStopped, content: message)
        }

        // Clean up
        desktopStreamContext = nil
        desktopStreamID = nil
        desktopStreamClientContext = nil
        desktopDisplayBounds = nil
        desktopUsesVirtualDisplay = false
        streamsByID.removeValue(forKey: streamID)
        udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()
        inputStreamCacheActor.remove(streamID)

        if desktopUsesVirtualDisplay {
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        }

        if activeStreams.isEmpty && loginDisplayContext == nil {
            await PowerAssertionManager.shared.disable()
        }

        MirageLogger.host("Desktop stream stopped")
    }

    /// Stop all active streams for desktop mode (mutual exclusivity)
    func stopAllStreamsForDesktopMode() async {
        MirageLogger.host("Stopping all streams for desktop mode")

        let sessions = await appStreamManager.getAllSessions()
        for session in sessions {
            MirageLogger.host("Ending app session: \(session.bundleIdentifier)")
            await appStreamManager.endSession(bundleIdentifier: session.bundleIdentifier)
        }

        for session in activeStreams {
            MirageLogger.host("Stopping window stream: \(session.id)")
            await stopStream(session, minimizeWindow: false)
        }
    }

    /// Find SCDisplay with retry - faster than fixed sleep
    func findSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        for attempt in 1...maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay()
                MirageLogger.host("Found SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                } else {
                    MirageLogger.error(.host, "Failed to find SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageError.protocolError("Failed to find SCDisplay")
    }

    /// Find main SCDisplay with retry - for desktop streaming capture
    func findMainSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        for attempt in 1...maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findMainSCDisplay()
                MirageLogger.host("Found main SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                } else {
                    MirageLogger.error(.host, "Failed to find main SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageError.protocolError("Failed to find main SCDisplay")
    }

    /// Set up display mirroring so ALL displays mirror the virtual display
    /// This allows the client to control the resolution - the virtual display is the source,
    /// and all other displays adapt to show what the virtual display shows.
    func setupDisplayMirroring(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = CGVirtualDisplayBridge.getDisplaysToMirror(excludingDisplayID: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return
        }

        MirageLogger.host("Setting up mirroring for \(displaysToMirror.count) displays")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration for mirroring")
            return
        }

        var successfullyMirrored: Set<CGDirectDisplayID> = []

        for displayID in displaysToMirror {
            // Skip if already mirroring the target
            if CGDisplayMirrorsDisplay(displayID) == targetDisplayID {
                successfullyMirrored.insert(displayID)
                continue
            }

            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetDisplayID)
            if result == .success {
                successfullyMirrored.insert(displayID)
                MirageLogger.host("Configured display \(displayID) to mirror virtual display")
            } else {
                MirageLogger.error(.host, "Failed to configure display \(displayID) for mirroring: \(result)")
            }
        }

        guard !successfullyMirrored.isEmpty else {
            MirageLogger.error(.host, "No displays configured for mirroring")
            CGCancelDisplayConfiguration(config)
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
        if completeResult != .success {
            MirageLogger.error(.host, "Failed to complete mirroring configuration: \(completeResult)")
            return
        }

        mirroredPhysicalDisplayIDs = successfullyMirrored
        MirageLogger.host("Display mirroring enabled for \(successfullyMirrored.count) displays → virtual display \(targetDisplayID)")
    }

    /// Disable display mirroring (restores all displays to independent mode)
    func disableDisplayMirroring(displayID: CGDirectDisplayID) async {
        guard !mirroredPhysicalDisplayIDs.isEmpty else {
            MirageLogger.host("No mirrored displays to restore")
            return
        }

        MirageLogger.host("Restoring \(mirroredPhysicalDisplayIDs.count) displays from mirroring")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to disable mirroring")
            return
        }

        var successfullyRestored = 0

        for mirroredDisplayID in mirroredPhysicalDisplayIDs {
            // Skip if no longer mirroring
            guard CGDisplayMirrorsDisplay(mirroredDisplayID) != kCGNullDirectDisplay else {
                continue
            }

            let result = CGConfigureDisplayMirrorOfDisplay(config, mirroredDisplayID, kCGNullDirectDisplay)
            if result == .success {
                successfullyRestored += 1
            } else {
                MirageLogger.error(.host, "Failed to disable mirroring for display \(mirroredDisplayID): \(result)")
            }
        }

        if successfullyRestored > 0 {
            let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
            if completeResult != .success {
                MirageLogger.error(.host, "Failed to complete disable mirroring: \(completeResult)")
            } else {
                MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
            }
        } else {
            CGCancelDisplayConfiguration(config)
        }

        mirroredPhysicalDisplayIDs.removeAll()
    }
}

#endif
