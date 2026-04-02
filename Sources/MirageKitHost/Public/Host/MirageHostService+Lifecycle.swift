//
//  MirageHostService+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host lifecycle and window refresh.
//

import Foundation
import Loom
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

        await HostDesktopStreamTerminationTracker.shared.reportUncleanTerminationIfNeeded()
        state = .starting
        MirageLogger.host("Starting...")

        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                try await startListeners()
                break
            } catch let error as NWError where Self.isAddressInUseError(error) {
                MirageLogger.host("Port already in use (attempt \(attempt + 1)/\(maxRetries)), cleaning up stale listeners...")
                await loomNode.stopAdvertising()

                if attempt < maxRetries - 1 {
                    state = .starting
                    try await Task.sleep(for: .seconds(1))
                } else {
                    state = .error(error.localizedDescription)
                    throw error
                }
            }
        }

        // Initial window refresh (non-blocking - may fail if no screen recording permission)
        do {
            try await refreshWindows()
            lastScreenRecordingPermissionDenied = false
            MirageLogger.host("Window refresh complete, found \(availableWindows.count) windows")
        } catch {
            lastScreenRecordingPermissionDenied = Self.isScreenRecordingPermissionDenied(error)
            MirageLogger.host("Initial window refresh failed (screen recording permission may be needed): \(error)")
        }

        ensureScreenParametersObserver()

        // Start cursor monitoring for active streams
        startCursorMonitoring()

        // Start session state monitoring (for headless Mac unlock support)
        await startSessionStateMonitoring()
    }

    private nonisolated static func isAddressInUseError(_ error: NWError) -> Bool {
        if case let .posix(code) = error, code == .EADDRINUSE { return true }
        return false
    }

    private nonisolated static func isScreenRecordingPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }

    private func startListeners() async throws {
        do {
            MirageLogger.host("Starting Loom authenticated listeners...")
            let ports = try await loomNode.startAuthenticatedAdvertising(
                serviceName: serviceName,
                helloProvider: { [weak self] in
                    guard let self else {
                        throw MirageError.protocolError("Host service deallocated during Loom hello creation")
                    }
                    return try await MainActor.run {
                        try self.makeSessionHelloRequest()
                    }
                }
            ) { [weak self] session in
                Task { @MainActor [weak self] in
                    await self?.handleIncomingSession(session)
                }
            }
            let controlPort = ports[.udp] ?? 0
            let directQUICPort = ports[.quic]
            setRemoteControlPort(directQUICPort)
            remoteControlListenerReady = directQUICPort != nil
            MirageLogger.host("Loom authenticated listeners ready udp=\(controlPort) quic=\(directQUICPort ?? 0)")

            state = .advertising(controlPort: controlPort)
            MirageLogger.host("Now advertising on control:\(controlPort)")
            await publishCurrentAdvertisement()
            startAdvertisementRefreshLoop()

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
            MirageLogger.error(.host, error: error, message: "Failed to start: ")
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        stopAdvertisementRefreshLoop()
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        clearAllPendingAppWindowCloseAlertTokens()
        await SharedVirtualDisplayManager.shared.setGenerationChangeHandler(nil)
        removeScreenParametersObserver()

        // Stop cursor monitoring
        await cursorMonitor?.stop()
        cursorMonitor = nil

        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        // Stop all streams
        for stream in activeStreams {
            await stopStream(stream)
        }
        windowVirtualDisplayStateByWindowID.removeAll()
        windowVisibleFrameDriftStateByStreamID.removeAll()
        windowPlacementRepairBackoffByWindowID.removeAll()

        // Disconnect all clients
        for client in connectedClients {
            await disconnectClient(client)
        }

        await restoreStageManagerAfterAppStreamingIfNeeded(force: true)

        hostAudioMuteController.setMuted(false)
        await forceDisableLightsOut(reason: "host service stop")

        // Force release power assertion on full stop
        await PowerAssertionManager.shared.forceDisable()

        await loomNode.stopAdvertising()

        state = .idle
        remoteControlListenerReady = false
        setRemoteControlPort(nil)
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
        for context in clientsBySessionID.values {
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
                clientContext.controlChannel.sendBestEffort(controlMessage)
            }
        }

        // End the session
        await appStreamManager.endSession(bundleIdentifier: bundleIdentifier)
        await stopAppStreamGovernorsIfIdle()
        await restoreStageManagerAfterAppStreamingIfNeeded()

        MirageLogger.host("Ended app stream for \(bundleIdentifier)")
    }

    func refreshWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false // Include minimized/off-screen windows
        )

        // Fetch extended metadata for alpha and visibility filtering.
        // Run off the main actor — CGWindowListCopyWindowInfo enumerates every
        // window on the system and can block for seconds on busy machines.
        let metadata = await Task.detached { fetchWindowMetadata() }.value

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
