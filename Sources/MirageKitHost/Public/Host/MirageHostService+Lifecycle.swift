//
//  MirageHostService+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host lifecycle and window refresh.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
import CoreGraphics
import ScreenCaptureKit

@MainActor
public extension MirageHostService {
    func getActiveStreamingSessions() async -> [MirageAppStreamSession] {
        await appStreamManager.getAllSessions()
    }

    func start() async throws {
        guard state == .idle else {
            MirageLogger.host("Already started, state: \(state)")
            return
        }

        state = .starting
        MirageLogger.host("Starting...")

        do {
            // Start TCP listener for control connections (handler passed directly)
            MirageLogger.host("Starting TCP listener on port \(networkConfig.controlPort)...")
            let controlPort = try await advertiser.start(port: networkConfig.controlPort) { [weak self] connection in
                Task { @MainActor [weak self] in
                    await self?.handleNewConnection(connection)
                }
            }
            MirageLogger.host("TCP listener started on port \(controlPort)")

            // Start UDP listener for data
            MirageLogger.host("Starting UDP listener...")
            let dataPort = try await startDataListener()
            MirageLogger.host("UDP listener started on port \(dataPort)")

            state = .advertising(controlPort: controlPort, dataPort: dataPort)
            MirageLogger.host("Now advertising on control:\(controlPort) data:\(dataPort)")
            await advertiser.updateCapabilities(advertisedCapabilities)
            await updateRemoteControlListenerState()

            // Set up app streaming callbacks
            setupAppStreamManagerCallbacks()
            await SharedVirtualDisplayManager.shared
                .setGenerationChangeHandler { [weak self] context, previousGeneration in
                    Task { @MainActor [weak self] in
                        await self?.handleSharedDisplayGenerationChange(
                            newContext: context,
                            previousGeneration: previousGeneration
                        )
                    }
                }
        } catch {
            MirageLogger.error(.host, "Failed to start: \(error)")
            state = .error(error.localizedDescription)
            throw error
        }

        // Initial window refresh (non-blocking - may fail if no screen recording permission)
        do {
            try await refreshWindows()
            MirageLogger.host("Window refresh complete, found \(availableWindows.count) windows")
        } catch {
            MirageLogger.host("Initial window refresh failed (screen recording permission may be needed): \(error)")
        }

        // Start cursor monitoring for active streams
        startCursorMonitoring()

        // Start session state monitoring (for headless Mac unlock support)
        await startSessionStateMonitoring()
    }

    func stop() async {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        stopLoginDisplayWatchdog()
        await SharedVirtualDisplayManager.shared.setGenerationChangeHandler(nil)

        // Stop cursor monitoring
        await cursorMonitor?.stop()
        cursorMonitor = nil

        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        // Stop all streams
        for stream in activeStreams {
            await stopStream(stream)
        }

        // Disconnect all clients
        for client in connectedClients {
            await disconnectClient(client)
        }

        await restoreStageManagerAfterAppStreamingIfNeeded(force: true)

        hostAudioMuteController.setMuted(false)
        cancelLightsOutScreenshotSuspension()
        lightsOutController.deactivate()

        // Force release power assertion on full stop
        await PowerAssertionManager.shared.forceDisable()

        await advertiser.stop()
        udpListener?.cancel()
        udpListener = nil

        state = .idle
        await updateRemoteControlListenerState()
    }

    func endAppStream(bundleIdentifier: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return }

        let windowIDs = Array(session.windowStreams.keys)

        // Stop all window streams for this app
        for windowID in windowIDs {
            if let stream = activeStreams.first(where: { $0.window.id == windowID }) {
                await stopStream(stream, updateAppSession: false)
            }
        }

        // Notify client that the app stream has ended
        var clientContext: ClientContext?
        for context in clientsByConnection.values {
            if context.client.id == session.clientID {
                clientContext = context
                break
            }
        }

        if let clientContext {
            // Check if client has other active sessions
            let allSessions = await appStreamManager.getAllSessions()
            let hasRemaining = allSessions.contains { sess in
                sess.clientID == session.clientID && sess.bundleIdentifier != bundleIdentifier
            }

            let message = AppTerminatedMessage(
                bundleIdentifier: bundleIdentifier,
                closedWindowIDs: windowIDs,
                hasRemainingWindows: hasRemaining
            )
            if let controlMessage = try? ControlMessage(type: .appTerminated, content: message) {
                let data = controlMessage.serialize()
                clientContext.tcpConnection.send(
                    content: data,
                    completion: NWConnection.SendCompletion.contentProcessed { _ in }
                )
            }
        }

        // End the session
        await appStreamManager.endSession(bundleIdentifier: bundleIdentifier)
        await restoreStageManagerAfterAppStreamingIfNeeded()

        MirageLogger.host("Ended app stream for \(bundleIdentifier)")
    }

    func refreshWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false // Include minimized/off-screen windows
        )

        // Fetch extended metadata for alpha and visibility filtering
        let metadata = fetchWindowMetadata()

        var windows: [MirageWindow] = []

        for scWindow in content.windows {
            // Skip small windows (hidden processes, system UI) - minimum 200x150
            guard scWindow.frame.width >= 200, scWindow.frame.height >= 150 else { continue }

            // Skip windows without titles (auxiliary panels, popovers, floating UI)
            guard let title = scWindow.title, !title.isEmpty else { continue }

            // Skip non-standard window layers (layer 0 = normal windows)
            guard scWindow.windowLayer == 0 else { continue }

            // Skip windows without an owning application
            guard let scApp = scWindow.owningApplication else { continue }

            // Skip invisible windows (alpha near zero) - keeps minimized windows which have normal alpha
            if let windowMeta = metadata[CGWindowID(scWindow.windowID)], windowMeta.alpha < 0.01 { continue }

            let app = MirageApplication(
                id: scApp.processID,
                bundleIdentifier: scApp.bundleIdentifier,
                name: scApp.applicationName,
                iconData: nil
            )

            let window = MirageWindow(
                id: WindowID(scWindow.windowID),
                title: scWindow.title,
                application: app,
                frame: scWindow.frame,
                isOnScreen: scWindow.isOnScreen,
                windowLayer: Int(scWindow.windowLayer)
            )

            windows.append(window)
        }

        // Collapse tabbed windows into single entries (tabs share the same frame)
        let filteredWindows = detectAndCollapseTabGroups(windows, metadata: metadata)

        availableWindows = filteredWindows.sorted { ($0.application?.name ?? "") < ($1.application?.name ?? "") }
    }
}
#endif
