//
//  MirageHostService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network

#if os(macOS)
import ScreenCaptureKit

// MARK: - Desktop Streaming

extension MirageHostService {
    /// Start streaming the desktop (mirrored or secondary display mode)
    /// This stops any active app/window streams for mutual exclusivity
    // TODO: HDR support - add hdr: Bool = false parameter when EDR configuration is figured out
    func startDesktopStream(
        to clientContext: ClientContext,
        displayResolution: CGSize,
        mode: MirageDesktopStreamMode,
        keyFrameInterval: Int?,
        pixelFormat: MiragePixelFormat?,
        colorSpace: MirageColorSpace?,
        captureQueueDepth: Int?,
        minBitrate: Int?,
        maxBitrate: Int?,
        streamScale: CGFloat?,
        latencyMode: MirageStreamLatencyMode = .smoothest,
        dataPort _: UInt16?,
        targetFrameRate: Int? = nil
    )
    async throws {
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

        let desktopStartTime = CFAbsoluteTimeGetCurrent()
        func logDesktopStartStep(_ step: String) {
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStartTime) * 1000)
            MirageLogger.host("Desktop start: \(step) (+\(deltaMs)ms)")
        }

        MirageLogger
            .host(
                "Starting desktop stream at \(Int(displayResolution.width))x\(Int(displayResolution.height)) (\(mode.displayName))"
            )
        logDesktopStartStep("request accepted")

        // Stop all active app/window streams (mutual exclusivity)
        await stopAllStreamsForDesktopMode()
        logDesktopStartStep("other streams stopped")

        // Clear any stuck modifiers from previous streams
        inputController.clearAllModifiers()
        desktopStreamMode = mode

        // Configure encoder with optional overrides
        var config = encoderConfig
        config = config.withOverrides(
            keyFrameInterval: keyFrameInterval,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            captureQueueDepth: captureQueueDepth,
            minBitrate: minBitrate,
            maxBitrate: maxBitrate
        )

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            minBitrate: config.minBitrate,
            maxBitrate: config.maxBitrate
        ) {
            config.minBitrate = normalized
            config.maxBitrate = normalized
        }

        if let targetFrameRate { config = config.withTargetFrameRate(targetFrameRate) }
        // TODO: HDR support - requires proper virtual display EDR configuration
        // if hdr {
        //     config.colorSpace = .hdr
        //     MirageLogger.host("Desktop stream HDR enabled (Rec. 2020 + PQ)")
        // }

        desktopBaseDisplayResolution = displayResolution
        let clampedStreamScale = StreamContext.clampStreamScale(streamScale ?? 1.0)
        desktopRequestedStreamScale = clampedStreamScale
        desktopUsesScaledVirtualDisplay = true
        let virtualDisplayResolution = resolvedDesktopVirtualDisplayResolution(
            baseResolution: displayResolution,
            streamScale: clampedStreamScale
        )
        let effectiveStreamScale: CGFloat = 1.0

        if clampedStreamScale < 1.0 {
            MirageLogger.host(
                "Desktop scale \(clampedStreamScale) → virtual display \(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)); encoder scale forced to 1.0"
            )
        }

        // Acquire virtual display at the resolved streaming resolution.
        // The 5K cap is applied at the encoding layer, not the virtual display.
        // Pass the target frame rate to enable 120Hz when appropriate.
        let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(
            for: targetFrameRate ?? 60
        )
        let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
            .desktopStream,
            resolution: virtualDisplayResolution,
            refreshRate: virtualDisplayRefreshRate,
            colorSpace: config.colorSpace
        )
        logDesktopStartStep("virtual display acquired (\(context.displayID))")

        let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
        logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
        let captureResolution = context.resolution

        desktopVirtualDisplayID = context.displayID
        var resolvedBounds = resolveDesktopDisplayBounds()
        if resolvedBounds == nil {
            resolvedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds()
        }
        guard let bounds = resolvedBounds else {
            throw MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
        }
        desktopDisplayBounds = bounds
        desktopUsesVirtualDisplay = true
        sharedVirtualDisplayGeneration = await SharedVirtualDisplayManager.shared.getDisplayGeneration()
        logDesktopStartStep("display bounds cached")

        if desktopPrimaryPhysicalDisplayID == nil {
            let primaryDisplayID = resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
            desktopPrimaryPhysicalDisplayID = primaryDisplayID
            desktopPrimaryPhysicalBounds = CGDisplayBounds(primaryDisplayID)
            MirageLogger
                .host(
                    "Desktop primary physical display: \(primaryDisplayID), bounds=\(desktopPrimaryPhysicalBounds ?? .zero)"
                )
        }

        if mode == .mirrored {
            // Set up display mirroring so physical displays mirror the virtual display.
            // This lets the virtual display drive the streamed resolution.
            await setupDisplayMirroring(targetDisplayID: context.displayID)
            logDesktopStartStep("display mirroring configured")
        } else {
            logDesktopStartStep("display mirroring skipped (secondary display)")
        }

        let streamID = nextStreamID
        nextStreamID += 1
        streamStartupBaseTimes[streamID] = desktopStartTime
        streamStartupRegistrationLogged.remove(streamID)
        streamStartupFirstPacketSent.remove(streamID)
        if captureDisplay.display.displayID != context.displayID {
            MirageLogger.error(
                .host,
                "Desktop capture display mismatch: capture=\(captureDisplay.display.displayID), virtual=\(context.displayID)"
            )
        }
        MirageLogger
            .host(
                "Desktop capture source: Virtual Display (capture display \(captureDisplay.display.displayID), virtual \(context.displayID), color=\(config.colorSpace.displayName))"
            )

        let effectiveScale = effectiveStreamScale

        let streamContext = StreamContext(
            streamID: streamID,
            windowID: 0,
            encoderConfig: config,
            streamScale: effectiveScale,
            maxPacketSize: networkConfig.maxPacketSize,
            additionalFrameFlags: [.desktopStream],
            latencyMode: latencyMode
        )
        await streamContext.setStartupBaseTime(desktopStartTime, label: "desktop stream \(streamID)")
        logDesktopStartStep("stream context created (\(streamID))")
        let metricsClientID = clientContext.client.id
        await streamContext.setMetricsUpdateHandler { [weak self] metrics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(clientID: metricsClientID) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    MirageLogger.error(.host, "Failed to send desktop stream metrics: \(error)")
                }
            }
        }

        desktopStreamContext = streamContext
        desktopStreamID = streamID
        desktopStreamClientContext = clientContext
        streamsByID[streamID] = streamContext

        await suspendAppListRequestsForDesktopStream()

        // Register for input handling.
        // For mirrored virtual displays, use the aspect-fit content bounds within the
        // physical display so input matches the mirrored content area.
        let mainDisplayBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputBounds = resolvedDesktopInputBounds(
            physicalBounds: mainDisplayBounds,
            virtualResolution: captureResolution
        )
        let desktopWindow = MirageWindow(
            id: 0,
            title: "Desktop",
            application: nil,
            frame: inputBounds,
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
            onEncodedFrame: { [weak self] packetData, _, releasePacket in
                guard let self else {
                    releasePacket()
                    return
                }
                Task { @MainActor in
                    self.sendVideoPacketForStream(streamID, data: packetData, onComplete: releasePacket)
                }
            }
        )
        logDesktopStartStep("capture and encoder started")

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
        logDesktopStartStep("desktopStreamStarted sent")

        MirageLogger
            .host(
                "Desktop stream started: streamID=\(streamID), resolution=\(encodedDimensions.width)x\(encodedDimensions.height)"
            )
    }

    /// Stop the desktop stream
    func stopDesktopStream(reason: DesktopStreamStopReason = .clientRequested) async {
        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        guard let streamID = desktopStreamID else { return }

        MirageLogger.host("Stopping desktop stream: streamID=\(streamID), reason=\(reason)")

        let wasUsingVirtualDisplay = desktopUsesVirtualDisplay
        let borrowedByLoginDisplay = loginDisplayIsBorrowedStream && loginDisplayStreamID == streamID
        let sharedDisplayID = wasUsingVirtualDisplay
            ? await SharedVirtualDisplayManager.shared.getDisplayID()
            : nil

        if let context = desktopStreamContext { await context.stop() }

        if desktopStreamMode == .mirrored, let sharedDisplayID {
            await disableDisplayMirroring(displayID: sharedDisplayID)
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
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopUsesVirtualDisplay = false
        desktopStreamMode = .mirrored
        desktopBaseDisplayResolution = nil
        desktopRequestedStreamScale = 1.0
        desktopUsesScaledVirtualDisplay = false
        streamsByID.removeValue(forKey: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupRegistrationLogged.remove(streamID)
        streamStartupFirstPacketSent.remove(streamID)
        udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()
        inputStreamCacheActor.remove(streamID)

        if wasUsingVirtualDisplay { await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream) }

        if borrowedByLoginDisplay {
            MirageLogger.host("Desktop stream was borrowed for login display; clearing borrowed login-display state")
            stopLoginDisplayWatchdog()
            loginDisplayWatchdogStartTime = 0
            loginDisplayStartInProgress = false
            loginDisplayStartGeneration &+= 1
            loginDisplayRetryTask?.cancel()
            loginDisplayRetryTask = nil
            loginDisplayRetryAttempts = 0
            let sharedConsumerActive = loginDisplaySharedDisplayConsumerActive
            loginDisplaySharedDisplayConsumerActive = false
            loginDisplayContext = nil
            loginDisplayStreamID = nil
            loginDisplayResolution = nil
            loginDisplayIsBorrowedStream = false
            loginDisplayPowerAssertionEnabled = false
            loginDisplayInputState.clear()

            if sharedConsumerActive { await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay) }

            if sessionState != .active, !clientsByConnection.isEmpty { await startLoginDisplayStreamIfNeeded() }
        }

        if activeStreams.isEmpty, loginDisplayContext == nil { await PowerAssertionManager.shared.disable() }

        resumePendingAppListRequestIfNeeded()

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
        var attemptDelayMs = max(10, Int(delayMs))
        for attempt in 1 ... maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay(maxAttempts: 1)
                MirageLogger.host("Found SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts {
                    MirageLogger
                        .host(
                            "SCDisplay not ready (attempt \(attempt)/\(maxAttempts)); retrying in \(attemptDelayMs)ms"
                        )
                    try? await Task.sleep(for: .milliseconds(attemptDelayMs))
                    attemptDelayMs = min(1000, Int(Double(attemptDelayMs) * 1.6))
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
        for attempt in 1 ... maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findMainSCDisplay()
                MirageLogger.host("Found main SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts { try await Task.sleep(for: .milliseconds(Int64(delayMs))) } else {
                    MirageLogger.error(.host, "Failed to find main SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageError.protocolError("Failed to find main SCDisplay")
    }

    func resolvePrimaryPhysicalDisplayID() -> CGDirectDisplayID? {
        let mainDisplayID = CGMainDisplayID()
        if !CGVirtualDisplayBridge.isVirtualDisplay(mainDisplayID) { return mainDisplayID }

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        return displays.first { !CGVirtualDisplayBridge.isVirtualDisplay($0) }
    }

    func resolvePhysicalDisplaysToMirror(excluding targetDisplayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        let candidates = CGVirtualDisplayBridge.getDisplaysToMirror(excludingDisplayID: targetDisplayID)
        return candidates.filter { !CGVirtualDisplayBridge.isVirtualDisplay($0) }
    }

    func captureDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID])
    -> [CGDirectDisplayID: CGDirectDisplayID] {
        var snapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for displayID in displayIDs {
            snapshot[displayID] = CGDisplayMirrorsDisplay(displayID)
        }
        return snapshot
    }

    /// Set up display mirroring so physical displays mirror the virtual display.
    /// This keeps the virtual display as the resolution source for streaming.
    func setupDisplayMirroring(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = resolvePhysicalDisplaysToMirror(excluding: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return
        }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
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
        MirageLogger
            .host(
                "Display mirroring enabled for \(successfullyMirrored.count) displays → virtual display \(targetDisplayID)"
            )
    }

    /// Restore display mirroring to the pre-stream configuration.
    func disableDisplayMirroring(displayID: CGDirectDisplayID) async {
        guard !desktopMirroringSnapshot.isEmpty else {
            MirageLogger.host("No display mirroring snapshot to restore")
            mirroredPhysicalDisplayIDs.removeAll()
            return
        }

        MirageLogger
            .host("Restoring \(desktopMirroringSnapshot.count) displays from mirroring (virtual display \(displayID))")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to disable mirroring")
            return
        }

        var successfullyRestored = 0

        for (displayID, mirroredDisplayID) in desktopMirroringSnapshot {
            let targetMirrorID = mirroredDisplayID == 0 ? kCGNullDirectDisplay : mirroredDisplayID
            guard CGDisplayMirrorsDisplay(displayID) != targetMirrorID else { continue }

            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetMirrorID)
            if result == .success { successfullyRestored += 1 } else {
                MirageLogger.error(.host, "Failed to restore mirroring for display \(displayID): \(result)")
            }
        }

        if successfullyRestored > 0 {
            let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
            if completeResult != .success { MirageLogger.error(.host, "Failed to complete disable mirroring: \(completeResult)") } else {
                MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
            }
        } else {
            CGCancelDisplayConfiguration(config)
        }

        mirroredPhysicalDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
    }
}

#endif
