import Foundation
import Network

#if os(macOS)
import ApplicationServices

// MARK: - App-Centric Streaming Handlers

extension MirageHostService {
    /// Find a client context by client ID
    func findClientContext(clientID: UUID) -> ClientContext? {
        clientsByConnection.values.first { $0.client.id == clientID }
    }

    /// Set up callbacks for AppStreamManager to notify clients of window changes
    func setupAppStreamManagerCallbacks() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Handle new window detected from streamed app
            await self.appStreamManager.setOnNewWindowDetected { [weak self] bundleID, scWindow in
                // Extract sendable data from SCWindow
                let windowID = WindowID(scWindow.windowID)
                Task { @MainActor in
                    await self?.handleNewWindowFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            // Handle window closed from streamed app
            await self.appStreamManager.setOnWindowClosed { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleWindowClosedFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            // Handle app terminated
            await self.appStreamManager.setOnAppTerminated { [weak self] bundleID in
                Task { @MainActor in
                    await self?.handleStreamedAppTerminated(bundleID: bundleID)
                }
            }

            // Handle cooldown expired
            await self.appStreamManager.setOnCooldownExpired { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleCooldownExpired(bundleID: bundleID, windowID: windowID)
                }
            }
        }
    }

    /// Handle new window appearing from a streamed app
    func handleNewWindowFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        // Check if this window is already streaming
        if session.windowStreams[windowID] != nil {
            return
        }

        let existingStreamID = session.windowStreams.values.first?.streamID
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let streamScale = await existingContext?.getStreamScale() ?? 1.0
        let adaptiveScaleEnabled = await existingContext?.getAdaptiveScaleEnabled() ?? true
        let encoderSettings = await existingContext?.getEncoderSettings()
        let targetFrameRate = await existingContext?.getTargetFrameRate()
        let qualityPreset = await existingContext?.getQualityPreset()

        // Check if there's a window in cooldown - if so, redirect to it
        if !session.windowsInCooldown.isEmpty {
            // Find a window in cooldown to redirect
            if let cooldownWindowID = session.windowsInCooldown.keys.first {
                // Cancel cooldown and stream to this window
                await appStreamManager.cancelCooldown(bundleIdentifier: bundleID, windowID: cooldownWindowID)

                // Refresh windows to get the MirageWindow
                try? await refreshWindows()
                guard let mirageWindow = availableWindows.first(where: { $0.id == windowID }) else {
                    return
                }

                // Start stream for the new window
                do {
                    let streamSession = try await startStream(
                        for: mirageWindow,
                        to: clientContext.client,
                        dataPort: nil,
                        clientDisplayResolution: nil,
                        keyFrameInterval: encoderSettings?.keyFrameInterval,
                        frameQuality: encoderSettings?.frameQuality,
                        keyframeQuality: encoderSettings?.keyframeQuality,
                        streamScale: streamScale,
                        adaptiveScaleEnabled: adaptiveScaleEnabled,
                        qualityPreset: qualityPreset,
                        targetFrameRate: targetFrameRate,
                        pixelFormat: encoderSettings?.pixelFormat,
                        colorSpace: encoderSettings?.colorSpace,
                        captureQueueDepth: encoderSettings?.captureQueueDepth,
                        minBitrate: encoderSettings?.minBitrate,
                        maxBitrate: encoderSettings?.maxBitrate
                    )

                    let isResizable = await appStreamManager.checkWindowResizability(
                        windowID: windowID,
                        processID: mirageWindow.application?.id ?? 0
                    )

                    await appStreamManager.addWindowToSession(
                        bundleIdentifier: bundleID,
                        windowID: windowID,
                        streamID: streamSession.id,
                        title: mirageWindow.title,
                        width: Int(mirageWindow.frame.width),
                        height: Int(mirageWindow.frame.height),
                        isResizable: isResizable
                    )

                    // Send cooldown cancelled message
                    let response = WindowCooldownCancelledMessage(
                        oldWindowID: cooldownWindowID,
                        newStreamID: streamSession.id,
                        newWindowID: windowID,
                        title: mirageWindow.title,
                        width: Int(mirageWindow.frame.width),
                        height: Int(mirageWindow.frame.height),
                        isResizable: isResizable
                    )
                    try? await clientContext.send(.windowCooldownCancelled, content: response)

                    MirageLogger.host("Redirected cooldown window \(cooldownWindowID) to new window \(windowID)")
                } catch {
                    MirageLogger.error(.host, "Failed to start stream for redirected window: \(error)")
                }
                return
            }
        }

        // No cooldown - this is a genuinely new window, stream it
        try? await refreshWindows()
        guard let mirageWindow = availableWindows.first(where: { $0.id == windowID }) else {
            return
        }

        do {
            let streamSession = try await startStream(
                for: mirageWindow,
                to: clientContext.client,
                dataPort: nil,
                clientDisplayResolution: nil,
                keyFrameInterval: encoderSettings?.keyFrameInterval,
                frameQuality: encoderSettings?.frameQuality,
                keyframeQuality: encoderSettings?.keyframeQuality,
                streamScale: streamScale,
                adaptiveScaleEnabled: adaptiveScaleEnabled,
                qualityPreset: qualityPreset,
                targetFrameRate: targetFrameRate,
                pixelFormat: encoderSettings?.pixelFormat,
                colorSpace: encoderSettings?.colorSpace,
                captureQueueDepth: encoderSettings?.captureQueueDepth,
                minBitrate: encoderSettings?.minBitrate,
                maxBitrate: encoderSettings?.maxBitrate
            )

            let isResizable = await appStreamManager.checkWindowResizability(
                windowID: windowID,
                processID: mirageWindow.application?.id ?? 0
            )

            await appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: windowID,
                streamID: streamSession.id,
                title: mirageWindow.title,
                width: Int(mirageWindow.frame.width),
                height: Int(mirageWindow.frame.height),
                isResizable: isResizable
            )

            // Send window added message
            let response = WindowAddedToStreamMessage(
                bundleIdentifier: bundleID,
                streamID: streamSession.id,
                windowID: windowID,
                title: mirageWindow.title,
                width: Int(mirageWindow.frame.width),
                height: Int(mirageWindow.frame.height),
                isResizable: isResizable
            )
            try? await clientContext.send(.windowAddedToStream, content: response)

            MirageLogger.host("Added new window \(windowID) to app stream \(bundleID)")
        } catch {
            MirageLogger.error(.host, "Failed to start stream for new window: \(error)")
        }
    }

    /// Handle window closed from a streamed app
    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID),
              let windowInfo = session.windowStreams[windowID] else {
            return
        }

        // Stop the stream for this window
        if let streamSession = activeStreams.first(where: { $0.id == windowInfo.streamID }) {
            await stopStream(streamSession, minimizeWindow: false)
        }

        // Enter cooldown for this window
        await appStreamManager.removeWindowFromSession(
            bundleIdentifier: bundleID,
            windowID: windowID,
            enterCooldown: true
        )

        // Send cooldown started message
        let response = WindowCooldownStartedMessage(
            windowID: windowID,
            durationSeconds: Int(await appStreamManager.windowCooldownDuration),
            message: "Window closed by host. Waiting for new window..."
        )
        try? await clientContext.send(.windowCooldownStarted, content: response)

        MirageLogger.host("Window \(windowID) entered cooldown for app \(bundleID)")
    }

    /// Handle streamed app terminating
    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        // Stop all streams for this app
        let windowIDs = Array(session.windowStreams.keys)
        for windowID in windowIDs {
            if let windowInfo = session.windowStreams[windowID],
               let streamSession = activeStreams.first(where: { $0.id == windowInfo.streamID }) {
                await stopStream(streamSession, minimizeWindow: false)
            }
        }

        // Check if client has other app sessions
        let allSessions = await appStreamManager.getAllSessions()
        let clientSessions = allSessions.filter { $0.clientID == session.clientID && $0.bundleIdentifier != bundleID }
        let hasRemainingWindows = !clientSessions.isEmpty

        // Send app terminated message
        let response = AppTerminatedMessage(
            bundleIdentifier: bundleID,
            closedWindowIDs: windowIDs,
            hasRemainingWindows: hasRemainingWindows
        )
        try? await clientContext.send(.appTerminated, content: response)

        // End the session
        await appStreamManager.endSession(bundleIdentifier: bundleID)

        MirageLogger.host("App \(bundleID) terminated, ended session")
    }

    /// Handle cooldown expired
    func handleCooldownExpired(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        // Send return to app selection message
        let response = ReturnToAppSelectionMessage(
            windowID: windowID,
            bundleIdentifier: bundleID,
            message: "No new window appeared. Returning to app selection."
        )
        try? await clientContext.send(.returnToAppSelection, content: response)

        MirageLogger.host("Cooldown expired for window \(windowID) in app \(bundleID)")
    }

    /// Handle request for list of installed apps
    func handleAppListRequest(_ message: ControlMessage, from client: MirageConnectedClient, connection: NWConnection) async {
        do {
            let request = try message.decode(AppListRequestMessage.self)
            MirageLogger.host("Client \(client.name) requested app list (icons: \(request.includeIcons))")

            let apps = await appStreamManager.getInstalledApps(includeIcons: request.includeIcons)

            let response = AppListMessage(apps: apps)
            let responseMessage = try ControlMessage(type: .appList, content: response)
            connection.send(content: responseMessage.serialize(), completion: .idempotent)

            MirageLogger.host("Sent \(apps.count) apps to \(client.name)")
        } catch {
            MirageLogger.error(.host, "Failed to handle app list request: \(error)")
        }
    }

    /// Handle request to stream an app
    func handleSelectApp(_ message: ControlMessage, from client: MirageConnectedClient, connection: NWConnection) async {
        do {
            let request = try message.decode(SelectAppMessage.self)
            MirageLogger.host("Client \(client.name) selected app: \(request.bundleIdentifier)")

            // Determine target frame rate based on client capability
            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = clientMaxRefreshRate >= 120 ? 120 : 60
            MirageLogger.host("Frame rate: \(targetFrameRate)fps (quality=\(request.preferredQuality.displayName), client max=\(clientMaxRefreshRate)Hz)")

            let presetConfig = request.preferredQuality.encoderConfiguration(for: targetFrameRate)
            let keyFrameInterval = request.keyFrameInterval ?? presetConfig.keyFrameInterval
            let frameQuality = request.frameQuality ?? presetConfig.frameQuality
            let keyframeQuality = request.keyframeQuality ?? presetConfig.keyframeQuality
            let pixelFormat = request.pixelFormat ?? presetConfig.pixelFormat
            let colorSpace = request.colorSpace ?? presetConfig.colorSpace
            let minBitrate = request.minBitrate ?? presetConfig.minBitrate
            let maxBitrate = request.maxBitrate ?? presetConfig.maxBitrate
            let streamScale = request.streamScale ?? 1.0
            let adaptiveScaleEnabled = request.adaptiveScaleEnabled ?? true

            // Check if app is available for streaming
            guard await appStreamManager.isAppAvailableForStreaming(request.bundleIdentifier) else {
                MirageLogger.host("App \(request.bundleIdentifier) is not available for streaming")
                // TODO: Send error response
                return
            }

            // Find the app in installed apps to get its path and name
            let apps = await appStreamManager.getInstalledApps(includeIcons: false)
            guard let app = apps.first(where: { $0.bundleIdentifier.lowercased() == request.bundleIdentifier.lowercased() }) else {
                MirageLogger.host("App \(request.bundleIdentifier) not found")
                return
            }

            // Start the app session
            guard let session = await appStreamManager.startAppSession(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                appPath: app.path,
                clientID: client.id,
                clientName: client.name
            ) else {
                MirageLogger.host("Failed to start app session for \(app.name)")
                return
            }

            // Launch the app if not running
            let launched = await appStreamManager.launchAppIfNeeded(app.bundleIdentifier, path: app.path)
            guard launched else {
                MirageLogger.host("Failed to launch app \(app.name)")
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                return
            }

            // Wait briefly for app to start and create windows
            try? await Task.sleep(for: .milliseconds(500))

            // Refresh windows and find windows for this app
            try? await refreshWindows()
            let appWindows = availableWindows.filter { window in
                window.application?.bundleIdentifier?.lowercased() == app.bundleIdentifier.lowercased()
            }

            if appWindows.isEmpty {
                // Try to request a new window
                await appStreamManager.requestNewWindow(bundleIdentifier: app.bundleIdentifier)
                try? await Task.sleep(for: .milliseconds(500))
                try? await refreshWindows()
            }

            // Get updated window list
            let finalWindows = availableWindows.filter { window in
                window.application?.bundleIdentifier?.lowercased() == app.bundleIdentifier.lowercased()
            }

            // Start streams for each window
            var streamedWindows: [AppStreamStartedMessage.AppStreamWindow] = []
            for window in finalWindows {
                do {
                    let streamSession = try await startStream(
                        for: window,
                        to: client,
                        dataPort: request.dataPort,
                        clientDisplayResolution: request.displayWidth != nil && request.displayHeight != nil
                            ? CGSize(width: request.displayWidth!, height: request.displayHeight!)
                            : nil,
                        keyFrameInterval: keyFrameInterval,
                        frameQuality: frameQuality,
                        keyframeQuality: keyframeQuality,
                        streamScale: streamScale,
                        adaptiveScaleEnabled: adaptiveScaleEnabled,
                        qualityPreset: request.preferredQuality,
                        targetFrameRate: targetFrameRate,
                        pixelFormat: pixelFormat,
                        colorSpace: colorSpace,
                        captureQueueDepth: request.captureQueueDepth,
                        minBitrate: minBitrate,
                        maxBitrate: maxBitrate
                    )

                    // Check window resizability
                    let isResizable = await appStreamManager.checkWindowResizability(
                        windowID: window.id,
                        processID: window.application?.id ?? 0
                    )

                    await appStreamManager.addWindowToSession(
                        bundleIdentifier: app.bundleIdentifier,
                        windowID: window.id,
                        streamID: streamSession.id,
                        title: window.title,
                        width: Int(window.frame.width),
                        height: Int(window.frame.height),
                        isResizable: isResizable
                    )

                    streamedWindows.append(AppStreamStartedMessage.AppStreamWindow(
                        streamID: streamSession.id,
                        windowID: window.id,
                        title: window.title,
                        width: Int(window.frame.width),
                        height: Int(window.frame.height),
                        isResizable: isResizable
                    ))
                } catch {
                    MirageLogger.error(.host, "Failed to start stream for window \(window.id): \(error)")
                }
            }

            // Mark session as streaming
            await appStreamManager.markSessionStreaming(app.bundleIdentifier)

            // Send response
            let response = AppStreamStartedMessage(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                windows: streamedWindows
            )
            let responseMessage = try ControlMessage(type: .appStreamStarted, content: response)
            connection.send(content: responseMessage.serialize(), completion: .idempotent)

            MirageLogger.host("Started streaming \(app.name) with \(streamedWindows.count) windows")
        } catch {
            MirageLogger.error(.host, "Failed to handle select app: \(error)")
        }
    }

    /// Handle request to close a window on the host
    func handleCloseWindowRequest(_ message: ControlMessage, from client: MirageConnectedClient, connection: NWConnection) async {
        do {
            let request = try message.decode(CloseWindowRequestMessage.self)
            MirageLogger.host("Client \(client.name) requested to close window \(request.windowID)")

            // Find the window and close it via Accessibility API
            guard let window = availableWindows.first(where: { $0.id == request.windowID }),
                  let app = window.application else {
                MirageLogger.host("Window \(request.windowID) not found")
                return
            }

            // Use AX API to close the window
            let appElement = AXUIElementCreateApplication(app.id)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement],
                  let axWindow = axWindows.first else { // Simplified - would need to match by window ID
                MirageLogger.host("Could not find AX window for \(request.windowID)")
                return
            }

            // Perform close action
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
               let closeButton = closeButtonRef {
                AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                MirageLogger.host("Closed window \(request.windowID)")
            }
        } catch {
            MirageLogger.error(.host, "Failed to handle close window request: \(error)")
        }
    }

    /// Handle stream paused notification
    func handleStreamPaused(_ message: ControlMessage, from client: MirageConnectedClient) async {
        do {
            let request = try message.decode(StreamPausedMessage.self)
            MirageLogger.host("Client \(client.name) paused stream \(request.streamID)")

            // Find the session and pause it
            if let session = await appStreamManager.getSessionForWindow(WindowID(request.streamID)) {
                await appStreamManager.pauseStream(
                    bundleIdentifier: session.bundleIdentifier,
                    streamID: request.streamID
                )
                // TODO: Add encoder throttling when StreamContext supports setTargetFrameRate
            }
        } catch {
            MirageLogger.error(.host, "Failed to handle stream paused: \(error)")
        }
    }

    /// Handle stream resumed notification
    func handleStreamResumed(_ message: ControlMessage, from client: MirageConnectedClient) async {
        do {
            let request = try message.decode(StreamResumedMessage.self)
            MirageLogger.host("Client \(client.name) resumed stream \(request.streamID)")

            // Find the session and resume it
            if let session = await appStreamManager.getSessionForWindow(WindowID(request.streamID)) {
                await appStreamManager.resumeStream(
                    bundleIdentifier: session.bundleIdentifier,
                    streamID: request.streamID
                )
                // TODO: Restore frame rate when StreamContext supports setTargetFrameRate
            }
        } catch {
            MirageLogger.error(.host, "Failed to handle stream resumed: \(error)")
        }
    }

    /// Handle cancel cooldown request
    func handleCancelCooldown(_ message: ControlMessage, from client: MirageConnectedClient, connection: NWConnection) async {
        do {
            let request = try message.decode(CancelCooldownMessage.self)
            MirageLogger.host("Client \(client.name) cancelled cooldown for window \(request.windowID)")

            // Find the session and cancel cooldown
            if let session = await appStreamManager.getSessionForWindow(request.windowID) {
                await appStreamManager.cancelCooldown(
                    bundleIdentifier: session.bundleIdentifier,
                    windowID: request.windowID
                )

                // Send return to app selection
                let response = ReturnToAppSelectionMessage(
                    windowID: request.windowID,
                    bundleIdentifier: session.bundleIdentifier,
                    message: "Cooldown cancelled"
                )
                let responseMessage = try ControlMessage(type: .returnToAppSelection, content: response)
                connection.send(content: responseMessage.serialize(), completion: .idempotent)
            }
        } catch {
            MirageLogger.error(.host, "Failed to handle cancel cooldown: \(error)")
        }
    }
}

#endif
