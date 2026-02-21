//
//  MirageHostService+Streams.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream lifecycle management.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
public extension MirageHostService {
    func startStream(
        for window: MirageWindow,
        to client: MirageConnectedClient,
        dataPort _: UInt16? = nil,
        clientDisplayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .auto,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool = true,
        disableResolutionCap: Bool = false,
        audioConfiguration: MirageAudioConfiguration? = nil
        // hdr: Bool = false
    )
    async throws -> MirageStreamSession {
        // Clear any stuck modifier state from previous streams
        inputController.clearAllModifiers()

        // Get the actual SCWindow, its owning application, and the display it's on
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { throw MirageError.windowNotFound }

        // Get the owning application (needed for app-level capture that includes alerts/sheets)
        guard let scApplication = scWindow.owningApplication else { throw MirageError.protocolError("Window has no owning application") }

        // Find the display containing this window (needed for app-level capture filter)
        guard let scDisplay = content.displays.first(where: { display in
            display.frame.contains(CGPoint(x: scWindow.frame.midX, y: scWindow.frame.midY))
        }) ?? content.displays.first else {
            throw MirageError.protocolError("No display found for window")
        }

        let streamID = nextStreamID
        nextStreamID += 1

        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: latestFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        let session = MirageStreamSession(
            id: streamID,
            window: updatedWindow,
            client: client
        )

        let effectiveEncoderConfig = resolveEncoderConfiguration(
            keyFrameInterval: keyFrameInterval,
            targetFrameRate: targetFrameRate,
            bitDepth: bitDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )
        guard mediaSecurityByClientID[client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for client")
        }

        // TODO: HDR support - requires proper virtual display EDR configuration
        // Apply HDR color space if requested
        // if hdr {
        //     effectiveEncoderConfig.colorSpace = .hdr
        //     MirageLogger.host("HDR streaming enabled (Rec. 2020 + PQ)")
        // }

        // Create stream context with capture and encoding
        let context = StreamContext(
            streamID: streamID,
            windowID: window.id,
            encoderConfig: effectiveEncoderConfig,
            streamScale: streamScale ?? 1.0,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: mediaSecurityByClientID[client.id],
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCap,
            latencyMode: latencyMode
        )
        if disableResolutionCap {
            MirageLogger.host("Resolution cap disabled for stream \(streamID)")
        }
        MirageLogger.host("Latency mode for stream \(streamID): \(latencyMode.displayName)")
        if allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for stream \(streamID)")
        }
        if !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for stream \(streamID)")
        }
        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.dispatchControlWork(clientID: client.id) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(clientID: client.id) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    MirageLogger.error(.host, "Failed to send stream metrics: \(error)")
                }
            }
        }

        streamsByID[streamID] = context
        registerTypingBurstRoute(streamID: streamID, context: context)
        activeStreams.append(session)

        let resolvedAudioConfiguration = audioConfiguration ?? .default
        await activateAudioForClient(
            clientID: client.id,
            sourceStreamID: streamID,
            configuration: resolvedAudioConfiguration
        )

        // Enable power assertion to prevent display sleep during streaming
        await PowerAssertionManager.shared.enable()

        // Add window to activity monitor for throttling inactive streams
        await addWindowToActivityMonitor(window.id)

        // Update input cache for fast input routing (thread-safe)
        inputStreamCacheActor.set(streamID, window: updatedWindow, client: client)

        // UDP connection will be set when client sends registration via UDP
        // The client connects to our data port and registers with the stream ID

        // Wrap ScreenCaptureKit types for safe sending across actor boundary
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let applicationWrapper = SCApplicationWrapper(application: scApplication)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        // Start capture with callback to send video data
        // This will throw if screen recording permission is not granted
        do {
            // Use virtual display if client provides display resolution, otherwise use legacy window capture
            if let displayResolution = clientDisplayResolution, displayResolution.width > 0,
               displayResolution.height > 0 {
                let virtualDisplayResolution = virtualDisplayPixelResolution(
                    for: displayResolution,
                    client: client
                )
                // Virtual display mode - captures entire virtual display at client resolution
                MirageLogger
                    .host(
                        "Starting stream with virtual display at " +
                            "\(Int(displayResolution.width))x\(Int(displayResolution.height)) pts " +
                            "(\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px)"
                    )

                try await context.startWithVirtualDisplay(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    clientDisplayResolution: virtualDisplayResolution,
                    onEncodedFrame: { [weak self] packetData, _, releasePacket in
                        guard let self else {
                            releasePacket()
                            return
                        }
                        sendVideoPacketForStream(streamID, data: packetData) { [weak self] error in
                            releasePacket()
                            guard let self, let error else { return }
                            dispatchMainWork {
                                await self.handleVideoSendError(streamID: streamID, error: error)
                            }
                        }
                    },
                    onContentBoundsChanged: { [weak self] bounds in
                        guard let self else { return }
                        dispatchControlWork(clientID: client.id) { [weak self] in
                            guard let self else { return }
                            await sendContentBoundsUpdate(streamID: streamID, bounds: bounds, to: client)
                        }
                    },
                    onNewWindowDetected: { [weak self] newWindow in
                        guard let self else { return }
                        dispatchControlWork(clientID: client.id) { [weak self] in
                            guard let self else { return }
                            // Auto-stream new independent windows to the same client
                            await handleNewIndependentWindow(
                                newWindow,
                                originalStreamID: streamID,
                                client: client
                            )
                        }
                    },
                    onVirtualDisplayReady: { [weak self] bounds in
                        // CRITICAL: Cache bounds IMMEDIATELY when display is ready
                        // This is awaited by StreamContext, ensuring it completes BEFORE
                        // window movement or capture setup - preventing race condition
                        // where the window centering timer fires before bounds are cached
                        guard let self else { return }
                        let generation = await SharedVirtualDisplayManager.shared.getDisplayGeneration()
                        let scale = await SharedVirtualDisplayManager.shared.getDisplaySnapshot()?.scaleFactor ?? 2.0
                        await MainActor.run {
                            self.sharedVirtualDisplayBounds = bounds
                            self.sharedVirtualDisplayGeneration = generation
                            self.sharedVirtualDisplayScaleFactor = max(1.0, scale)
                            self.windowsUsingVirtualDisplay.insert(window.id)
                            MirageLogger.host("Cached virtual display bounds immediately: \(bounds)")
                        }
                    }
                )

                // Update input cache with window's new frame after moving to virtual display
                // Use the known virtual display bounds to avoid stale CGWindowList values
                if let bounds = sharedVirtualDisplayBounds {
                    let newFrame = CGRect(origin: bounds.origin, size: updatedWindow.frame.size)
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
                } else if let newFrame = currentWindowFrame(for: window.id) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
                }
            } else {
                // Legacy window capture mode
                try await context.start(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    displayWrapper: displayWrapper
                ) { [weak self] packetData, _, releasePacket in
                    guard let self else {
                        releasePacket()
                        return
                    }
                    sendVideoPacketForStream(streamID, data: packetData) { [weak self] error in
                        releasePacket()
                        guard let self, let error else { return }
                        dispatchMainWork {
                            await self.handleVideoSendError(streamID: streamID, error: error)
                        }
                    }
                }
            }
        } catch {
            // Capture failed (likely permission issue) - clean up and rethrow
            MirageLogger.error(.host, "Failed to start capture: \(error)")
            await context.stop()
            streamsByID.removeValue(forKey: streamID)
            activeStreams.removeAll { $0.id == streamID }
            await deactivateAudioSourceIfNeeded(streamID: streamID)
            throw error
        }

        // Activate the window/app being streamed
        // This ensures the window receives input correctly, even on virtual displays
        activateWindow(updatedWindow)

        // Only notify client AFTER capture successfully started
        if let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) {
            let minSize = minimumSizesByWindowID[updatedWindow.id]
            let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
            let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
            let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

            let encodedDimensions = await context.getEncodedDimensions()
            let targetFrameRate = await context.getTargetFrameRate()
            let codec = await context.getCodec()

            // Get dimension token from stream context
            let dimensionToken = await context.getDimensionToken()

            let message = StreamStartedMessage(
                streamID: streamID,
                windowID: window.id,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: targetFrameRate,
                codec: codec,
                minWidth: minWidth,
                minHeight: minHeight,
                dimensionToken: dimensionToken
            )
            try await clientContext.send(.streamStarted, content: message)
        }

        // Start menu bar monitoring for this stream
        if let app = updatedWindow.application { await startMenuBarMonitoring(streamID: streamID, app: app, client: client) }

        await updateLightsOutState()

        return session
    }

    private func resolveEncoderConfiguration(
        keyFrameInterval: Int?,
        targetFrameRate: Int?,
        bitDepth: MirageVideoBitDepth?,
        captureQueueDepth: Int?,
        bitrate: Int?
    ) -> MirageEncoderConfiguration {
        var effectiveEncoderConfig = encoderConfig
        if keyFrameInterval != nil || bitDepth != nil || captureQueueDepth != nil || bitrate != nil {
            effectiveEncoderConfig = encoderConfig.withOverrides(
                keyFrameInterval: keyFrameInterval,
                bitDepth: bitDepth,
                captureQueueDepth: captureQueueDepth,
                bitrate: bitrate
            )
            if let interval = keyFrameInterval { MirageLogger.host("Using client-requested keyframe interval: \(interval) frames") }
            if let bitDepth { MirageLogger.host("Using client-requested bit depth: \(bitDepth.displayName)") }
            if let captureQueueDepth { MirageLogger.host("Using client-requested capture queue depth: \(captureQueueDepth)") }
            if let bitrate { MirageLogger.host("Using client-requested bitrate: \(bitrate)") }
        }

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: effectiveEncoderConfig.bitrate
        ) {
            effectiveEncoderConfig.bitrate = normalized
        }

        // Apply target frame rate override if specified (based on P2P + client capability)
        if let targetFrameRate {
            effectiveEncoderConfig = effectiveEncoderConfig.withTargetFrameRate(targetFrameRate)
            MirageLogger.host("Using target frame rate: \(targetFrameRate)fps")
        }

        return effectiveEncoderConfig
    }

    func stopStream(
        _ session: MirageStreamSession,
        minimizeWindow: Bool = false,
        updateAppSession: Bool = true
    )
    async {
        guard let context = streamsByID[session.id] else { return }

        // Clear any stuck modifier state when stream ends
        inputController.clearAllModifiers()

        // Stop menu bar monitoring for this stream
        await stopMenuBarMonitoring(streamID: session.id)

        // Capture window ID before cleanup for minimize
        let windowID = session.window.id

        // Remove window from activity monitor
        await windowActivityMonitor?.removeWindow(windowID)

        // Remove window from virtual display tracking
        windowsUsingVirtualDisplay.remove(windowID)

        // Clear shared bounds if no more windows using virtual display
        if windowsUsingVirtualDisplay.isEmpty {
            sharedVirtualDisplayBounds = nil
            sharedVirtualDisplayScaleFactor = 2.0
        }

        await context.stop()
        streamsByID.removeValue(forKey: session.id)
        unregisterTypingBurstRoute(streamID: session.id)
        activeStreams.removeAll { $0.id == session.id }
        await deactivateAudioSourceIfNeeded(streamID: session.id)

        // Remove from input cache (thread-safe)
        inputStreamCacheActor.remove(session.id)

        // Clean up UDP connection for this stream
        if let udpConnection = udpConnectionsByStream.removeValue(forKey: session.id) { udpConnection.cancel() }
        transportRegistry.unregisterVideoConnection(streamID: session.id)

        // Minimize the window if requested (after stopping capture so window is restored from virtual display)
        if minimizeWindow { WindowManager.minimizeWindow(windowID) }

        if updateAppSession {
            await removeStoppedWindowFromAppSessionIfNeeded(windowID: windowID)
        }

        await updateLightsOutState()

        if activeStreams.isEmpty {
            // Stop activity monitor when no more streams are active
            await windowActivityMonitor?.stop()
            windowActivityMonitor = nil

            // Disable power assertion when no more streams are active (including login display)
            if loginDisplayStreamID == nil { await PowerAssertionManager.shared.disable() }
        }
    }

    func notifyWindowResized(_ window: MirageWindow) async {
        // Find any active streams for this window and update their dimensions
        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: latestFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        for index in activeStreams.indices where activeStreams[index].window.id == window.id {
            let session = activeStreams[index]
            guard let context = streamsByID[session.id] else { continue }

            activeStreams[index] = MirageStreamSession(
                id: session.id,
                window: updatedWindow,
                client: session.client
            )

            // Update input cache with new frame - critical for mouse coordinate translation
            inputStreamCacheActor.updateWindowFrame(session.id, newFrame: latestFrame)

            do {
                // Update capture/encoder to scaled resolution
                try await context.updateDimensions(windowFrame: updatedWindow.frame)

                let encodedDimensions = await context.getEncodedDimensions()
                let targetFrameRate = await context.getTargetFrameRate()
                let codec = await context.getCodec()

                // Get updated dimension token after resize
                let dimensionToken = await context.getDimensionToken()

                if let clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id }) {
                    let minSize = minimumSizesByWindowID[updatedWindow.id]
                    let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
                    let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                    let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                    let message = StreamStartedMessage(
                        streamID: session.id,
                        windowID: window.id,
                        width: encodedDimensions.width,
                        height: encodedDimensions.height,
                        frameRate: targetFrameRate,
                        codec: codec,
                        minWidth: minWidth,
                        minHeight: minHeight,
                        dimensionToken: dimensionToken
                    )
                    try await clientContext.send(.streamStarted, content: message)
                    MirageLogger
                        .host("Encoding at scaled resolution: \(encodedDimensions.width)x\(encodedDimensions.height)")
                }
            } catch {
                MirageLogger.error(.host, "Failed to update stream dimensions: \(error)")
            }
        }
    }

    func updateCaptureResolution(for windowID: WindowID, width: Int, height: Int) async {
        // Find the stream for this window
        guard let session = activeStreams.first(where: { $0.window.id == windowID }),
              let context = streamsByID[session.id] else {
            MirageLogger.host("No active stream found for window \(windowID)")
            return
        }

        // Get the latest window frame for calculations
        let latestFrame = currentWindowFrame(for: windowID) ?? session.window.frame

        // Update the window frame in the active stream (maintains position metadata)
        if let index = activeStreams.firstIndex(where: { $0.window.id == windowID }) {
            let currentSession = activeStreams[index]
            let updatedWindow = MirageWindow(
                id: currentSession.window.id,
                title: currentSession.window.title,
                application: currentSession.window.application,
                frame: latestFrame,
                isOnScreen: currentSession.window.isOnScreen,
                windowLayer: currentSession.window.windowLayer
            )
            activeStreams[index] = MirageStreamSession(
                id: currentSession.id,
                window: updatedWindow,
                client: currentSession.client
            )
        }

        do {
            // Request client's exact resolution - with .best, SCK will capture at highest quality
            try await context.updateResolution(width: width, height: height)

            // Get updated dimension token after resize
            let dimensionToken = await context.getDimensionToken()

            // Notify the client of the dimensions
            if let clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = minimumSizesByWindowID[windowID]
                let fallbackMin = fallbackMinimumSize(for: latestFrame)
                let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                let message = await StreamStartedMessage(
                    streamID: session.id,
                    windowID: windowID,
                    width: width,
                    height: height,
                    frameRate: context.getTargetFrameRate(),
                    codec: encoderConfig.codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: dimensionToken
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger.host("Capture resolution updated to \(width)x\(height)")
            }
        } catch {
            MirageLogger.error(.host, "Failed to update capture resolution: \(error)")
        }
    }
}
#endif
