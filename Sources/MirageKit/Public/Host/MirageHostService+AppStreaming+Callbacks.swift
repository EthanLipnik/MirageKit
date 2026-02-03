//
//  MirageHostService+AppStreaming+Callbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream callbacks.
//

import Foundation
import Network

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    func findClientContext(clientID: UUID) -> ClientContext? {
        clientsByConnection.values.first { $0.client.id == clientID }
    }

    func setupAppStreamManagerCallbacks() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Handle new window detected from streamed app
            await appStreamManager.setOnNewWindowDetected { [weak self] bundleID, scWindow in
                // Extract sendable data from SCWindow
                let windowID = WindowID(scWindow.windowID)
                Task { @MainActor in
                    await self?.handleNewWindowFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            // Handle window closed from streamed app
            await appStreamManager.setOnWindowClosed { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleWindowClosedFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            // Handle app terminated
            await appStreamManager.setOnAppTerminated { [weak self] bundleID in
                Task { @MainActor in
                    await self?.handleStreamedAppTerminated(bundleID: bundleID)
                }
            }

            // Handle cooldown expired
            await appStreamManager.setOnCooldownExpired { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleCooldownExpired(bundleID: bundleID, windowID: windowID)
                }
            }
        }
    }

    func handleNewWindowFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        // Check if this window is already streaming
        if session.windowStreams[windowID] != nil { return }

        let existingStreamID = session.windowStreams.values.first?.streamID
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let streamScale = await existingContext?.getStreamScale() ?? 1.0
        let encoderSettings = await existingContext?.getEncoderSettings()
        let targetFrameRate = await existingContext?.getTargetFrameRate()
        let qualityPreset = await existingContext?.getQualityPreset()
        let usesVirtualDisplay = await existingContext?.isUsingVirtualDisplay() ?? false
        let sharedDisplayResolution: CGSize? = if usesVirtualDisplay {
            await SharedVirtualDisplayManager.shared.getDisplayBounds()?.size
        } else {
            nil
        }

        // Check if there's a window in cooldown - if so, redirect to it
        if !session.windowsInCooldown.isEmpty {
            // Find a window in cooldown to redirect
            if let cooldownWindowID = session.windowsInCooldown.keys.first {
                // Cancel cooldown and stream to this window
                await appStreamManager.cancelCooldown(bundleIdentifier: bundleID, windowID: cooldownWindowID)

                // Refresh windows to get the MirageWindow
                try? await refreshWindows()
                guard let mirageWindow = availableWindows.first(where: { $0.id == windowID }) else { return }

                // Start stream for the new window
                do {
                    let streamSession = try await startStream(
                        for: mirageWindow,
                        to: clientContext.client,
                        dataPort: nil,
                        clientDisplayResolution: sharedDisplayResolution,
                        keyFrameInterval: encoderSettings?.keyFrameInterval,
                        streamScale: streamScale,
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
        guard let mirageWindow = availableWindows.first(where: { $0.id == windowID }) else { return }

        do {
            let streamSession = try await startStream(
                for: mirageWindow,
                to: clientContext.client,
                dataPort: nil,
                clientDisplayResolution: sharedDisplayResolution,
                keyFrameInterval: encoderSettings?.keyFrameInterval,
                streamScale: streamScale,
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

    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID),
              let windowInfo = session.windowStreams[windowID] else {
            return
        }

        // Stop the stream for this window
        if let streamSession = activeStreams.first(where: { $0.id == windowInfo.streamID }) { await stopStream(streamSession, minimizeWindow: false) }

        // Enter cooldown for this window
        await appStreamManager.removeWindowFromSession(
            bundleIdentifier: bundleID,
            windowID: windowID,
            enterCooldown: true
        )

        // Send cooldown started message
        let response = await WindowCooldownStartedMessage(
            windowID: windowID,
            durationSeconds: Int(appStreamManager.windowCooldownDuration),
            message: "Window closed by host. Waiting for new window..."
        )
        try? await clientContext.send(.windowCooldownStarted, content: response)

        MirageLogger.host("Window \(windowID) entered cooldown for app \(bundleID)")
    }

    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        // Clear any stuck modifiers when app terminates
        inputController.clearAllModifiers()

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
}

#endif
