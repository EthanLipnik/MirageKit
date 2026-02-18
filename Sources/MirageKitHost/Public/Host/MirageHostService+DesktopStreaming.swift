//
//  MirageHostService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network
import MirageKit

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
        bitDepth: MirageVideoBitDepth?,
        captureQueueDepth: Int?,
        bitrate: Int?,
        allowRuntimeQualityAdjustment: Bool?,
        disableResolutionCap: Bool,
        streamScale: CGFloat?,
        audioConfiguration: MirageAudioConfiguration,
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
        guard mediaSecurityByClientID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for desktop stream client")
        }

        let desktopStartTime = CFAbsoluteTimeGetCurrent()
        func logDesktopStartStep(_ step: String) {
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStartTime) * 1000)
            MirageLogger.host("Desktop start: \(step) (+\(deltaMs)ms)")
        }

        let virtualDisplayResolution = virtualDisplayPixelResolution(
            for: displayResolution,
            client: clientContext.client
        )
        MirageLogger
            .host(
                "Starting desktop stream at " +
                    "\(Int(displayResolution.width))x\(Int(displayResolution.height)) pts " +
                    "(\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px) " +
                    "(\(mode.displayName))"
            )
        logDesktopStartStep("request accepted")

        // Stop all active app/window streams (mutual exclusivity)
        await stopAllStreamsForDesktopMode()
        logDesktopStartStep("other streams stopped")

        // Clear any stuck modifiers from previous streams
        inputController.clearAllModifiers()
        desktopStreamMode = mode
        resetDesktopResizeTransactionState()

        // Configure encoder with optional overrides
        var config = encoderConfig
        config = config.withOverrides(
            keyFrameInterval: keyFrameInterval,
            bitDepth: bitDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: config.bitrate
        ) {
            config.bitrate = normalized
        }

        if let targetFrameRate { config = config.withTargetFrameRate(targetFrameRate) }
        // TODO: HDR support - requires proper virtual display EDR configuration
        // if hdr {
        //     config.colorSpace = .hdr
        //     MirageLogger.host("Desktop stream HDR enabled (Rec. 2020 + PQ)")
        // }

        let clampedStreamScale = StreamContext.clampStreamScale(streamScale ?? 1.0)
        if disableResolutionCap {
            MirageLogger.host("Desktop stream resolution cap disabled")
        }

        if clampedStreamScale < 1.0 {
            MirageLogger.host(
                "Desktop scale \(clampedStreamScale) → capture/encoder downscale; virtual display stays at " +
                    "\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px"
            )
        }

        // Acquire virtual display at the resolved streaming resolution.
        // The 5K cap is applied at the encoding layer, not the virtual display.
        // Pass the target frame rate to enable 120Hz when appropriate.
        let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(
            for: targetFrameRate ?? 60
        )
        var captureDisplay: SCDisplayWrapper
        var captureResolution: CGSize

        do {
            let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                .desktopStream,
                resolution: virtualDisplayResolution,
                refreshRate: virtualDisplayRefreshRate,
                colorSpace: config.colorSpace
            )
            logDesktopStartStep("virtual display acquired (\(context.displayID))")

            captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
            logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
            captureResolution = context.resolution

            desktopVirtualDisplayID = context.displayID
            var resolvedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds()
            if resolvedBounds == nil { resolvedBounds = resolveDesktopDisplayBounds() }
            guard let bounds = resolvedBounds else {
                throw MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
            }
            desktopDisplayBounds = bounds
            desktopUsesVirtualDisplay = true
            sharedVirtualDisplayGeneration = await SharedVirtualDisplayManager.shared.getDisplayGeneration()
            sharedVirtualDisplayScaleFactor = max(1.0, context.scaleFactor)
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
        } catch {
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
            desktopVirtualDisplayID = nil
            desktopUsesVirtualDisplay = false
            sharedVirtualDisplayGeneration = 0
            sharedVirtualDisplayScaleFactor = 1.0
            desktopDisplayBounds = nil

            MirageLogger.error(
                .host,
                "Virtual display acquisition failed for desktop stream; using main display fallback: \(error)"
            )
            logDesktopStartStep("virtual display unavailable, falling back")

            do {
                captureDisplay = try await findMainSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
            } catch {
                MirageLogger.error(
                    .host,
                    "Main SCDisplay fallback lookup failed; trying first available display: \(error)"
                )
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                guard let anyDisplay = content.displays.first else {
                    throw MirageError.protocolError("No ScreenCaptureKit display available for fallback capture")
                }
                captureDisplay = SCDisplayWrapper(display: anyDisplay)
                MirageLogger.host(
                    "Using first available SCDisplay for fallback capture: \(anyDisplay.displayID) (\(anyDisplay.width)x\(anyDisplay.height))"
                )
            }
            logDesktopStartStep("fallback SCDisplay resolved (\(captureDisplay.display.displayID))")
            captureResolution = CGSize(
                width: CGFloat(captureDisplay.display.width),
                height: CGFloat(captureDisplay.display.height)
            )

            let fallbackDisplayID = captureDisplay.display.displayID
            let fallbackBounds = CGDisplayBounds(fallbackDisplayID)
            if fallbackBounds.width > 0, fallbackBounds.height > 0 {
                desktopDisplayBounds = fallbackBounds
            } else {
                desktopDisplayBounds = CGRect(origin: .zero, size: captureResolution)
            }

            let primaryDisplayID = resolvePrimaryPhysicalDisplayID() ?? fallbackDisplayID
            desktopPrimaryPhysicalDisplayID = primaryDisplayID
            desktopPrimaryPhysicalBounds = CGDisplayBounds(primaryDisplayID)
            logDesktopStartStep("fallback bounds cached")

            MirageLogger
                .host(
                    "Desktop capture source: Main Display fallback (display \(fallbackDisplayID), color=\(config.colorSpace.displayName), resolution=\(Int(captureResolution.width))x\(Int(captureResolution.height)))"
                )
        }

        let streamID = nextStreamID
        nextStreamID += 1
        streamStartupBaseTimes[streamID] = desktopStartTime
        streamStartupRegistrationLogged.remove(streamID)
        streamStartupFirstPacketSent.remove(streamID)
        let streamContext = StreamContext(
            streamID: streamID,
            windowID: 0,
            encoderConfig: config,
            streamScale: clampedStreamScale,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: mediaSecurityByClientID[clientContext.client.id],
            additionalFrameFlags: [.desktopStream],
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            disableResolutionCap: disableResolutionCap,
            latencyMode: .auto
        )
        await streamContext.setStartupBaseTime(desktopStartTime, label: "desktop stream \(streamID)")
        logDesktopStartStep("stream context created (\(streamID))")
        if allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for desktop stream \(streamID)")
        }
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
        await activateAudioForClient(
            clientID: clientContext.client.id,
            sourceStreamID: streamID,
            configuration: audioConfiguration
        )

        await updateLightsOutState()
        let excludedWindows = await resolveLightsOutExcludedWindows()

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
            excludedWindows: excludedWindows,
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
        if clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            logDesktopStartStep("desktopStreamStarted queued")
        } else {
            MirageLogger.error(.host, "Failed to encode desktopStreamStarted message")
            logDesktopStartStep("desktopStreamStarted encoding failed")
        }

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
        resetDesktopResizeTransactionState()

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
        sharedVirtualDisplayScaleFactor = 2.0
        desktopStreamMode = .mirrored
        streamsByID.removeValue(forKey: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupRegistrationLogged.remove(streamID)
        streamStartupFirstPacketSent.remove(streamID)
        udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()
        inputStreamCacheActor.remove(streamID)
        await deactivateAudioSourceIfNeeded(streamID: streamID)

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

        await updateLightsOutState()

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

        await restoreStageManagerAfterAppStreamingIfNeeded()
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

        let mirroredDisplayIDs = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        if mirroredDisplayIDs.count == displaysToMirror.count {
            if desktopMirroringSnapshot.isEmpty {
                desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
                MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
            }
            mirroredPhysicalDisplayIDs = Set(displaysToMirror)
            MirageLogger.host("Display mirroring already enabled for \(displaysToMirror.count) displays")
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

    /// Temporarily suspend desktop mirroring before a virtual-display resize.
    /// This keeps resize transactions deterministic and avoids resize+mirror contention.
    func suspendDisplayMirroringForResize(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = resolvePhysicalDisplaysToMirror(excluding: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        let mirroredToTarget = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        guard !mirroredToTarget.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to suspend mirroring")
            return
        }

        var suspendedCount = 0
        for displayID in mirroredToTarget {
            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            if result == .success {
                suspendedCount += 1
            } else {
                MirageLogger.error(.host, "Failed to suspend mirroring for display \(displayID): \(result)")
            }
        }

        guard suspendedCount > 0 else {
            CGCancelDisplayConfiguration(config)
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
        if completeResult != .success {
            MirageLogger.error(.host, "Failed to complete mirroring suspend: \(completeResult)")
            return
        }

        mirroredPhysicalDisplayIDs.removeAll()
        MirageLogger.host("Temporarily suspended mirroring for \(suspendedCount) displays before resize")
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
