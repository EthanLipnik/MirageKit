//
//  MirageHostService+LoginDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Login Display Streaming

extension MirageHostService {
    /// Start login display stream if not already running
    func startLoginDisplayStreamIfNeeded() async {
        guard sessionState != .active else { return }
        guard !clientsByConnection.isEmpty else {
            MirageLogger.host("Skipping login display start: no connected clients")
            return
        }
        guard loginDisplayContext == nil else {
            await broadcastLoginDisplayReady()
            return
        }
        guard !loginDisplayStartInProgress else {
            MirageLogger.host("Login display start already in progress")
            return
        }

        // Clear any stale login-display consumer reference before starting a new stream.
        if loginDisplaySharedDisplayConsumerActive {
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay)
            loginDisplaySharedDisplayConsumerActive = false
        }

        // If a desktop stream exists, reuse it rather than creating a separate stream.
        if let desktopContext = desktopStreamContext, let desktopStreamID {
            MirageLogger.host("Reusing desktop stream \(desktopStreamID) for login display")

            stopLoginDisplayWatchdog()
            loginDisplayWatchdogStartTime = CFAbsoluteTimeGetCurrent()
            loginDisplayRetryTask?.cancel()
            loginDisplayRetryTask = nil
            loginDisplayRetryAttempts = 0

            loginDisplayStartGeneration &+= 1
            loginDisplayIsBorrowedStream = true
            loginDisplayPowerAssertionEnabled = false
            loginDisplaySharedDisplayConsumerActive = false

            loginDisplayContext = desktopContext
            loginDisplayStreamID = desktopStreamID

            let encodedDimensions = await desktopContext.getEncodedDimensions()
            let resolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
            loginDisplayResolution = resolution

            let mainBounds = resolvedMainDisplayBounds(
                displayID: CGMainDisplayID(),
                fallbackResolution: resolution
            )
            loginDisplayInputState.update(streamID: desktopStreamID, bounds: mainBounds)

            await broadcastLoginDisplayReady()
            return
        }

        loginDisplayStartInProgress = true
        loginDisplayRetryTask?.cancel()
        loginDisplayRetryTask = nil
        loginDisplayStartGeneration &+= 1
        let generation = loginDisplayStartGeneration
        if let connectedClient = connectedClients.first,
           mediaSecurityByClientID[connectedClient.id] == nil {
            MirageLogger.error(.host, "Cannot start login display without media security context for client \(connectedClient.name)")
            return
        }

        let streamID = nextStreamID
        nextStreamID += 1
        let loginClientID = connectedClients.first?.id

        let context = StreamContext(
            streamID: streamID,
            windowID: 0,
            encoderConfig: encoderConfig,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: loginClientID.flatMap { mediaSecurityByClientID[$0] },
            additionalFrameFlags: [.loginDisplay],
            latencyMode: .auto
        )

        // Mark the stream as active before awaiting so reentrant state changes can stop it.
        loginDisplayIsBorrowedStream = false
        loginDisplayContext = context
        loginDisplayStreamID = streamID
        loginDisplayResolution = nil
        loginDisplayPowerAssertionEnabled = false
        loginDisplaySharedDisplayConsumerActive = false

        streamsByID[streamID] = context
        if let connectedClient = connectedClients.first {
            let configuration = audioConfigurationByClientID[connectedClient.id] ?? .default
            await activateAudioForClient(
                clientID: connectedClient.id,
                sourceStreamID: streamID,
                configuration: configuration
            )
        }
        stopLoginDisplayWatchdog()
        loginDisplayWatchdogStartTime = CFAbsoluteTimeGetCurrent()
        loginDisplayInputState.update(streamID: streamID, bounds: provisionalMainDisplayBounds())

        func shouldContinueStart(expectedGeneration: UInt64) -> Bool {
            guard expectedGeneration == loginDisplayStartGeneration else { return false }
            guard sessionState != .active else { return false }
            guard !clientsByConnection.isEmpty else { return false }
            guard loginDisplayStreamID == streamID else { return false }
            guard loginDisplayContext === context else { return false }
            return true
        }

        func cleanupOwnedStream(disablePowerAssertion: Bool) async {
            await context.stop()
            streamsByID.removeValue(forKey: streamID)
            udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()
            await deactivateAudioSourceIfNeeded(streamID: streamID)
            loginDisplayContext = nil
            loginDisplayStreamID = nil
            loginDisplayResolution = nil
            loginDisplayIsBorrowedStream = false
            loginDisplayInputState.clear()
            stopLoginDisplayWatchdog()
            loginDisplayWatchdogStartTime = 0

            let sharedConsumerActive = loginDisplaySharedDisplayConsumerActive
            loginDisplaySharedDisplayConsumerActive = false
            if sharedConsumerActive { await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay) }

            if disablePowerAssertion, loginDisplayPowerAssertionEnabled {
                await PowerAssertionManager.shared.disable()
                loginDisplayPowerAssertionEnabled = false
            }
        }

        defer {
            loginDisplayStartInProgress = false
        }

        do {
            let displayInfo = try await resolveLoginDisplayMainDisplay()

            guard shouldContinueStart(expectedGeneration: generation) else {
                MirageLogger.host("Login display start cancelled while resolving display")
                await cleanupOwnedStream(disablePowerAssertion: false)
                return
            }

            // Enable power assertion to prevent display sleep during login display streaming
            await PowerAssertionManager.shared.enable()
            loginDisplayPowerAssertionEnabled = true

            guard shouldContinueStart(expectedGeneration: generation) else {
                MirageLogger.host("Login display start cancelled before capture start")
                await cleanupOwnedStream(disablePowerAssertion: true)
                return
            }

            loginDisplayResolution = displayInfo.resolution
            loginDisplayInputState.update(streamID: streamID, bounds: displayInfo.bounds)

            // Clear any stuck modifiers before starting capture
            inputController.clearAllModifiers()

            try await context.startLoginDisplay(
                displayWrapper: displayInfo.displayWrapper,
                resolution: displayInfo.resolution,
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

            guard shouldContinueStart(expectedGeneration: generation) else {
                MirageLogger.host("Login display start cancelled after capture start")
                await cleanupOwnedStream(disablePowerAssertion: true)
                return
            }

            loginDisplayRetryAttempts = 0

            loginDisplayWatchdogStartTime = CFAbsoluteTimeGetCurrent()
            startLoginDisplayWatchdog(streamID: streamID, context: context)

            let encodedDimensions = await context.getEncodedDimensions()
            loginDisplayResolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)

            await broadcastLoginDisplayReady()
        } catch {
            MirageLogger.error(.host, "Failed to start login display stream: \(error)")
            await cleanupOwnedStream(disablePowerAssertion: true)
            await scheduleLoginDisplayRetry(reason: "start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the login display stream
    func stopLoginDisplayStream(newState: HostSessionState) async {
        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        stopLoginDisplayWatchdog()
        loginDisplayWatchdogStartTime = 0
        loginDisplayStartInProgress = false
        loginDisplayStartGeneration &+= 1
        loginDisplayRetryTask?.cancel()
        loginDisplayRetryTask = nil
        loginDisplayRetryAttempts = 0
        let sharedConsumerActive = loginDisplaySharedDisplayConsumerActive
        loginDisplaySharedDisplayConsumerActive = false

        guard let streamID = loginDisplayStreamID else {
            loginDisplayContext = nil
            loginDisplayIsBorrowedStream = false
            loginDisplayPowerAssertionEnabled = false
            loginDisplayInputState.clear()
            if sharedConsumerActive { await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay) }
            return
        }

        let isBorrowed = loginDisplayIsBorrowedStream
        if !isBorrowed, let context = loginDisplayContext { await context.stop() }

        loginDisplayContext = nil
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        loginDisplayIsBorrowedStream = false
        loginDisplayInputState.clear()

        if !isBorrowed {
            streamsByID.removeValue(forKey: streamID)
            udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()
            await deactivateAudioSourceIfNeeded(streamID: streamID)
        }

        if loginDisplayPowerAssertionEnabled {
            await PowerAssertionManager.shared.disable()
            loginDisplayPowerAssertionEnabled = false
        }

        if sharedConsumerActive { await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay) }

        await broadcastLoginDisplayStopped(streamID: streamID, newState: newState)
    }

    func startLoginDisplayWatchdog(streamID: StreamID, context: StreamContext) {
        loginDisplayWatchdogTask?.cancel()
        loginDisplayWatchdogGeneration &+= 1
        let generation = loginDisplayWatchdogGeneration

        loginDisplayWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: loginDisplayWatchdogInterval)
                if Task.isCancelled { return }
                await checkLoginDisplayHealth(generation: generation, streamID: streamID, context: context)
            }
        }
    }

    func stopLoginDisplayWatchdog() {
        loginDisplayWatchdogTask?.cancel()
        loginDisplayWatchdogTask = nil
        loginDisplayWatchdogGeneration &+= 1
    }

    func checkLoginDisplayHealth(generation: UInt64, streamID: StreamID, context: StreamContext) async {
        guard generation == loginDisplayWatchdogGeneration else { return }
        guard sessionState != .active else {
            stopLoginDisplayWatchdog()
            return
        }
        guard !loginDisplayStartInProgress else { return }
        guard !loginDisplayIsBorrowedStream else { return }
        guard loginDisplayStreamID == streamID else { return }
        guard let currentContext = loginDisplayContext, currentContext === context else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let startAge = loginDisplayWatchdogStartTime > 0 ? (now - loginDisplayWatchdogStartTime) : 0
        guard startAge >= loginDisplayWatchdogStartGraceSeconds else { return }

        let lastCaptureTime = await context.getLastCapturedFrameTime()
        let captureGapSeconds: CFAbsoluteTime = if lastCaptureTime > 0 {
            now - lastCaptureTime
        } else {
            startAge
        }

        guard captureGapSeconds >= loginDisplayWatchdogStaleThresholdSeconds else { return }

        let cooldownRemaining = loginDisplayRestartCooldownSeconds - (now - lastLoginDisplayRestartTime)
        if cooldownRemaining > 0 {
            let remainingText = max(0, cooldownRemaining).formatted(.number.precision(.fractionLength(1)))
            MirageLogger
                .host("Login display watchdog: stale capture but restart cooldown active (\(remainingText)s remaining)")
            return
        }

        lastLoginDisplayRestartTime = now
        let gapText = max(0, captureGapSeconds).formatted(.number.precision(.fractionLength(1)))
        MirageLogger.error(
            .host,
            "Login display watchdog: no recent frames for \(gapText)s, restarting login display stream"
        )
        await restartLoginDisplayStream(reason: "watchdog detected stale capture gap of \(gapText)s")
    }

    func restartLoginDisplayStream(reason: String) async {
        guard sessionState != .active else { return }
        guard !clientsByConnection.isEmpty else {
            await stopLoginDisplayStream(newState: sessionState)
            return
        }
        guard !loginDisplayIsBorrowedStream else {
            MirageLogger.host("Login display restart skipped while borrowing a desktop stream")
            return
        }
        guard !loginDisplayStartInProgress else { return }

        // Clear any stuck modifiers before restarting
        inputController.clearAllModifiers()

        MirageLogger.host("Restarting login display stream: \(reason)")
        await stopLoginDisplayStream(newState: sessionState)
        await startLoginDisplayStreamIfNeeded()
    }

    /// Broadcast login display ready to all connected clients
    func broadcastLoginDisplayReady() async {
        guard let streamID = loginDisplayStreamID,
              let resolution = loginDisplayResolution else {
            return
        }

        // Get dimension token from login display stream context
        let dimensionToken = await loginDisplayContext?.getDimensionToken() ?? 0

        let message = LoginDisplayReadyMessage(
            streamID: UInt32(streamID),
            width: Int(resolution.width),
            height: Int(resolution.height),
            sessionState: sessionState,
            requiresUsername: sessionState.requiresUsername,
            dimensionToken: dimensionToken
        )

        for clientContext in clientsByConnection.values {
            try? await clientContext.send(.loginDisplayReady, content: message)
        }
    }

    /// Broadcast login display stopped to all connected clients
    func broadcastLoginDisplayStopped(streamID: StreamID, newState: HostSessionState) async {
        let message = LoginDisplayStoppedMessage(
            streamID: UInt32(streamID),
            newState: newState
        )

        for clientContext in clientsByConnection.values {
            try? await clientContext.send(.loginDisplayStopped, content: message)
        }
    }

    func scheduleLoginDisplayRetry(reason: String) async {
        guard loginDisplayRetryTask == nil else { return }
        guard sessionState != .active else { return }
        guard !clientsByConnection.isEmpty else { return }
        guard loginDisplayContext == nil else { return }
        guard loginDisplayRetryAttempts < loginDisplayRetryLimit else {
            MirageLogger.error(
                .host,
                "Login display retry limit reached (\(loginDisplayRetryLimit)); last reason: \(reason)"
            )
            return
        }

        loginDisplayRetryAttempts += 1
        let attempt = loginDisplayRetryAttempts
        let delay = loginDisplayRetryDelay

        MirageLogger.host("Scheduling login display retry \(attempt)/\(loginDisplayRetryLimit) in \(delay) (\(reason))")

        loginDisplayRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            loginDisplayRetryTask = nil

            guard sessionState != .active else { return }
            guard !clientsByConnection.isEmpty else { return }
            guard loginDisplayContext == nil else { return }

            await startLoginDisplayStreamIfNeeded()
        }
    }

    func provisionalMainDisplayBounds() -> CGRect {
        let mainDisplayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainDisplayID)
        if bounds.width > 0, bounds.height > 0 { return bounds }
        return CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080))
    }

    func resolvedMainDisplayBounds(displayID: CGDirectDisplayID, fallbackResolution: CGSize) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        if bounds.width > 0, bounds.height > 0 { return bounds }
        return CGRect(origin: .zero, size: fallbackResolution)
    }

    /// Resolve the login display for streaming from the main display without creating a separate display
    func resolveLoginDisplayMainDisplay() async throws
    -> (displayWrapper: SCDisplayWrapper, displayID: CGDirectDisplayID, resolution: CGSize, bounds: CGRect) {
        do {
            let scDisplay = try await findMainSCDisplayWithRetry(maxAttempts: 8, delayMs: 120)
            let resolution = CGSize(width: scDisplay.display.width, height: scDisplay.display.height)
            let bounds = resolvedMainDisplayBounds(
                displayID: scDisplay.display.displayID,
                fallbackResolution: resolution
            )
            MirageLogger
                .host(
                    "Login display using main display \(scDisplay.display.displayID) at \(Int(resolution.width))x\(Int(resolution.height))"
                )
            return (
                displayWrapper: scDisplay,
                displayID: scDisplay.display.displayID,
                resolution: resolution,
                bounds: bounds
            )
        } catch {
            let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: 60)
            let sharedContext = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                .loginDisplay,
                refreshRate: refreshRate,
                colorSpace: encoderConfig.colorSpace
            )
            loginDisplaySharedDisplayConsumerActive = true

            let scDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 80)
            let resolution = sharedContext.resolution
            let bounds = await SharedVirtualDisplayManager.shared.getDisplayBounds()
                ?? CGRect(origin: .zero, size: resolution)
            MirageLogger
                .host(
                    "Login display using shared display \(scDisplay.display.displayID) at \(Int(resolution.width))x\(Int(resolution.height))"
                )
            return (
                displayWrapper: scDisplay,
                displayID: sharedContext.displayID,
                resolution: resolution,
                bounds: bounds
            )
        }
    }
}

#endif
