//
//  MirageHostService+AppStreaming+Requests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream request handling.
//

import Foundation
import Network

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
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
            let latencyMode = request.latencyMode ?? .smoothest

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
                        latencyMode: latencyMode,
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
