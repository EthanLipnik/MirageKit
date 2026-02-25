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
        clientScaleFactor: CGFloat? = nil,
        keyFrameInterval: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .auto,
        performanceMode: MirageStreamPerformanceMode = .standard,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool = true,
        disableResolutionCap: Bool = false,
        audioConfiguration: MirageAudioConfiguration? = nil
        // hdr: Bool = false
    )
    async throws -> MirageStreamSession {
        // Clear any stuck modifier state from previous streams
        inputController.clearAllModifiers()

        // Resolve capture sources from live ScreenCaptureKit content to avoid stale host window IDs.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let captureSource = try resolveCaptureSource(for: window, from: content)
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let fallbackDisplayWrapper = SCDisplayWrapper(display: captureSource.display)
        let resolvedWindowID = WindowID(scWindow.windowID)
        if resolvedWindowID != window.id {
            MirageLogger.host("Resolved window \(window.id) to live window \(resolvedWindowID) for stream start")
        }

        guard let clientDisplayResolution,
              clientDisplayResolution.width > 0,
              clientDisplayResolution.height > 0 else {
            throw MirageError.protocolError("App/window streaming requires a client display resolution")
        }

        let streamID = nextStreamID
        nextStreamID += 1

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let resolvedWindowFrame = scWindow.frame
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? resolvedWindowFrame
        let updatedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? window.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
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
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = if performanceMode == .game {
            .tuned
        } else {
            .baseline
        }
        let context = StreamContext(
            streamID: streamID,
            windowID: updatedWindow.id,
            encoderConfig: effectiveEncoderConfig,
            streamScale: streamScale ?? 1.0,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: mediaSecurityContextForMediaPayload(clientID: client.id),
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCap,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            performanceMode: performanceMode
        )
        if disableResolutionCap {
            MirageLogger.host("Resolution cap disabled for stream \(streamID)")
        }
        MirageLogger.host("Performance mode for stream \(streamID): \(performanceMode.displayName)")
        if performanceMode != .game {
            MirageLogger.host("Latency mode for stream \(streamID): \(latencyMode.displayName)")
        }
        if performanceMode != .game, allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for stream \(streamID)")
        }
        if performanceMode != .game, !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for stream \(streamID)")
        }
        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.dispatchControlWork(clientID: client.id) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(clientID: client.id) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to send stream metrics: ")
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

        // Update input cache for fast input routing (thread-safe)
        inputStreamCacheActor.set(streamID, window: updatedWindow, client: client)

        // UDP connection will be set when client sends registration via UDP
        // The client connects to our data port and registers with the stream ID

        // Wrap ScreenCaptureKit types for safe sending across actor boundary
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let applicationWrapper = SCApplicationWrapper(application: scApplication)

        // Start capture with callback to send video data
        // This will throw if screen recording permission is not granted
        let onEncodedFrame: @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void = {
            [weak self] packetData, _, releasePacket in
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

        do {
            let resolvedClientScaleFactor: CGFloat? = if let clientScaleFactor, clientScaleFactor > 0 {
                max(1.0, clientScaleFactor)
            } else {
                nil
            }
            let virtualDisplayResolution = virtualDisplayPixelResolution(
                for: clientDisplayResolution,
                client: client,
                scaleFactorOverride: resolvedClientScaleFactor
            )
            await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded()
            MirageLogger
                .host(
                    "Starting stream with virtual display at " +
                        "\(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height)) pts " +
                        "(\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px)"
                )

            try await context.startWithVirtualDisplay(
                windowWrapper: windowWrapper,
                applicationWrapper: applicationWrapper,
                clientDisplayResolution: virtualDisplayResolution,
                onEncodedFrame: onEncodedFrame,
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
                        await handleNewIndependentWindow(
                            newWindow,
                            originalStreamID: streamID,
                            client: client
                        )
                    }
                },
                onVirtualDisplayReady: { [weak self] snapshot, bounds in
                    guard let self else { return }
                    let resolvedClientScale = resolvedClientScaleFactor ?? max(1.0, snapshot.scaleFactor)
                    let state = WindowVirtualDisplayState(
                        streamID: streamID,
                        displayID: snapshot.displayID,
                        generation: snapshot.generation,
                        bounds: bounds,
                        scaleFactor: max(1.0, snapshot.scaleFactor),
                        pixelResolution: snapshot.resolution,
                        clientScaleFactor: resolvedClientScale
                    )
                    await MainActor.run {
                        self.setVirtualDisplayState(windowID: updatedWindow.id, state: state)
                        MirageLogger.host(
                            "Cached dedicated virtual display for window \(updatedWindow.id): display=\(snapshot.displayID), bounds=\(bounds)"
                        )
                    }
                }
            )

            if let bounds = getVirtualDisplayBounds(windowID: updatedWindow.id) {
                inputStreamCacheActor.updateWindowFrame(streamID, newFrame: bounds)
                MirageLogger.host("Updated input cache with new frame after virtual display move: \(bounds)")
            } else if let newFrame = currentWindowFrame(for: updatedWindow.id) {
                inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
            }

            let usesVirtualDisplay = await context.isUsingVirtualDisplay()
            if !usesVirtualDisplay {
                await addWindowToActivityMonitor(updatedWindow.id)
            }
        } catch let virtualDisplayError {
            // Dedicated virtual-display startup is preferred for app/window streams, but
            // fail-safe fallback to direct window capture avoids startup dead-ends.
            MirageLogger.error(
                .host,
                error: virtualDisplayError,
                message: "Virtual-display stream start failed, attempting direct window capture fallback: "
            )
            await context.stop()
            clearVirtualDisplayState(windowID: updatedWindow.id)

            do {
                try await context.start(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    displayWrapper: fallbackDisplayWrapper,
                    onEncodedFrame: onEncodedFrame
                )
                if let resolvedFrame = currentWindowFrame(for: updatedWindow.id) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: resolvedFrame)
                }
                await addWindowToActivityMonitor(updatedWindow.id)
                MirageLogger.host("Started stream \(streamID) with direct window capture fallback")
            } catch {
                MirageLogger.error(.host, error: error, message: "Direct window capture fallback failed: ")
                await context.stop()
                clearVirtualDisplayState(windowID: updatedWindow.id)
                streamsByID.removeValue(forKey: streamID)
                activeStreams.removeAll { $0.id == streamID }
                await deactivateAudioSourceIfNeeded(streamID: streamID)
                throw error
            }
        }

        // Activate the window/app being streamed.
        // Dedicated-display streams capture the display surface, so reassert placement in case
        // activation APIs hop the window back to a physical desktop space.
        activateWindow(updatedWindow)
        if isStreamUsingVirtualDisplay(windowID: updatedWindow.id) {
            await enforceVirtualDisplayPlacementAfterActivation(windowID: updatedWindow.id)
            scheduleVirtualDisplayPlacementReassert(windowID: updatedWindow.id)
        }

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
                windowID: updatedWindow.id,
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
        MirageInstrumentation.record(.hostStreamWindowStartedPerformanceMode(.init(rawMode: performanceMode.rawValue)))

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

    private func enforceVirtualDisplayPlacementAfterActivation(windowID: WindowID) async {
        guard let state = getVirtualDisplayState(windowID: windowID) else { return }

        let resolvedSpaceID = CGVirtualDisplayBridge.getSpaceForDisplay(state.displayID)
        guard resolvedSpaceID != 0 else {
            MirageLogger.host("Skipping placement reassert for window \(windowID): no active space for display \(state.displayID)")
            return
        }

        do {
            try await WindowSpaceManager.shared.moveWindow(
                windowID,
                toSpaceID: resolvedSpaceID,
                displayID: state.displayID,
                displayBounds: state.bounds
            )
            inputStreamCacheActor.updateWindowFrame(state.streamID, newFrame: state.bounds)
            MirageLogger.host("Reasserted virtual-display placement for window \(windowID) on display \(state.displayID)")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to reassert virtual-display placement for window \(windowID): "
            )
        }
    }

    private func scheduleVirtualDisplayPlacementReassert(windowID: WindowID) {
        let retryDelays: [Duration] = [
            .milliseconds(120),
            .milliseconds(260),
            .milliseconds(520),
        ]

        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in retryDelays {
                try? await Task.sleep(for: delay)
                guard isStreamUsingVirtualDisplay(windowID: windowID) else { return }
                await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)
            }
        }
    }

    private struct StreamCaptureSource {
        let window: SCWindow
        let application: SCRunningApplication
        let display: SCDisplay
    }

    private func resolveCaptureSource(
        for requestedWindow: MirageWindow,
        from content: SCShareableContent
    ) throws -> StreamCaptureSource {
        if let directWindow = content.windows.first(where: { $0.windowID == requestedWindow.id }),
           let directApp = directWindow.owningApplication,
           let directDisplay = resolveDisplayForCaptureWindow(directWindow, displays: content.displays) {
            return StreamCaptureSource(window: directWindow, application: directApp, display: directDisplay)
        }

        let requestedBundleID = requestedWindow.application?.bundleIdentifier?.lowercased()
        let requestedPID = requestedWindow.application?.id
        let fallbackCandidates = content.windows
            .filter { candidate in
                guard let candidateApp = candidate.owningApplication else { return false }
                if let requestedPID, candidateApp.processID == requestedPID { return true }
                guard let requestedBundleID else { return false }
                return candidateApp.bundleIdentifier.lowercased() == requestedBundleID
            }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                if lhs.windowLayer != rhs.windowLayer { return lhs.windowLayer < rhs.windowLayer }
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                return lhsArea > rhsArea
            }

        for candidate in fallbackCandidates {
            guard let candidateApp = candidate.owningApplication,
                  let candidateDisplay = resolveDisplayForCaptureWindow(candidate, displays: content.displays) else {
                continue
            }
            return StreamCaptureSource(window: candidate, application: candidateApp, display: candidateDisplay)
        }

        throw MirageError.windowNotFound
    }

    private func resolveDisplayForCaptureWindow(_ window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return containingDisplay
        }

        var bestIntersectionArea: CGFloat = 0
        var bestDisplay: SCDisplay?
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }
        if let bestDisplay { return bestDisplay }

        return displays.first
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

        // Remove dedicated virtual display state for this window.
        clearVirtualDisplayState(windowID: windowID)

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

            if isStreamUsingVirtualDisplay(windowID: window.id) {
                if let bounds = getVirtualDisplayBounds(windowID: window.id) {
                    inputStreamCacheActor.updateWindowFrame(session.id, newFrame: bounds)
                }
                continue
            }

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
                MirageLogger.error(.host, error: error, message: "Failed to update stream dimensions: ")
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
        if isStreamUsingVirtualDisplay(windowID: windowID) {
            MirageLogger.host(
                "Ignoring capture-resolution resize for window \(windowID) using dedicated virtual display"
            )
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
            MirageLogger.error(.host, error: error, message: "Failed to update capture resolution: ")
        }
    }
}
#endif
