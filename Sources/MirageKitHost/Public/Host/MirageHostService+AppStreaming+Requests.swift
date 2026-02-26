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
import MirageKit

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    func handleAppListRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection _: NWConnection
    )
    async {
        do {
            let request = try message.decode(AppListRequestMessage.self)
            MirageLogger.host(
                "Client \(client.name) requested app list (icons: \(request.includeIcons), forceRefresh: \(request.forceRefresh))"
            )

            updatePendingAppListRequest(
                clientID: client.id,
                requestedIcons: request.includeIcons,
                requestedForceRefresh: request.forceRefresh
            )

            if desktopStreamContext != nil {
                MirageLogger.host("Deferring app list request while desktop stream is active")
                return
            }

            sendPendingAppListRequestIfPossible()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle app list request: ")
        }
    }

    func handleSelectApp(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(SelectAppMessage.self)
            guard !disconnectingClientIDs.contains(client.id),
                  clientsByID[client.id] != nil else {
                MirageLogger.host("Ignoring selectApp from disconnected client \(client.name)")
                return
            }
            MirageLogger.host("Client \(client.name) selected app: \(request.bundleIdentifier)")
            await pruneOrphanedAppSessions()

            // Determine target frame rate based on client capability
            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)
            MirageLogger
                .host(
                    "Frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)"
                )

            let latencyMode = request.latencyMode ?? .auto
            let performanceMode = request.performanceMode ?? .standard
            guard let displayWidth = request.displayWidth,
                  let displayHeight = request.displayHeight,
                  displayWidth > 0,
                  displayHeight > 0 else {
                MirageLogger.host("Rejecting app stream request without display size")
                let error = ErrorMessage(
                    code: .invalidMessage,
                    message: "App streaming requires displayWidth/displayHeight"
                )
                if let response = try? ControlMessage(type: .error, content: error) {
                    connection.send(content: response.serialize(), completion: .idempotent)
                }
                return
            }
            let requestedDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Performance mode: \(performanceMode.displayName)")

            // Check if app is available for streaming
            guard await appStreamManager.isAppAvailableForStreaming(request.bundleIdentifier) else {
                MirageLogger.host("App \(request.bundleIdentifier) is not available for streaming")
                let error = ErrorMessage(
                    code: .windowNotFound,
                    message: "App is unavailable for streaming: \(request.bundleIdentifier)"
                )
                if let response = try? ControlMessage(type: .error, content: error) {
                    connection.send(content: response.serialize(), completion: .idempotent)
                }
                return
            }

            // Find the app in installed apps to get its path and name
            let apps = await appStreamManager.getInstalledApps(includeIcons: false)
            guard let app = apps
                .first(where: { $0.bundleIdentifier.lowercased() == request.bundleIdentifier.lowercased() }) else {
                MirageLogger.host("App \(request.bundleIdentifier) not found")
                sendAppSelectionError(over: connection, code: .windowNotFound, message: "App not found: \(request.bundleIdentifier)")
                return
            }
            pendingLightsOutSetup = true
            await beginPendingAppStreamLightsOutSetup()
            await prepareStageManagerForAppStreamingIfNeeded()

            // Start the app session
            guard await appStreamManager.startAppSession(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                appPath: app.path,
                clientID: client.id,
                clientName: client.name,
                requestedDisplayResolution: requestedDisplayResolution,
                requestedClientScaleFactor: request.scaleFactor
            ) != nil else {
                MirageLogger.host("Failed to start app session for \(app.name)")
                sendAppSelectionError(
                    over: connection,
                    code: .windowNotFound,
                    message: "\(app.name) is already being streamed to another client"
                )
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            // Launch the app if not running
            let launched = await appStreamManager.launchAppIfNeeded(app.bundleIdentifier, path: app.path)
            guard launched else {
                MirageLogger.host("Failed to launch app \(app.name)")
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                sendAppSelectionError(
                    over: connection,
                    code: .windowNotFound,
                    message: "Failed to launch \(app.name)"
                )
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            let startupResult = await startInitialAppWindowStreams(
                app: app,
                client: client,
                selectRequest: request,
                targetFrameRate: targetFrameRate,
                requestedDisplayResolution: requestedDisplayResolution
            )
            guard !startupResult.windows.isEmpty else {
                MirageLogger.host(
                    "No window streams started for \(app.name); ending session (reason: \(startupResult.failureSummary))"
                )
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                sendAppSelectionError(
                    over: connection,
                    code: .windowNotFound,
                    message: "Failed to start \(app.name): \(startupResult.failureSummary)"
                )
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

            await appStreamManager.markSessionStreaming(app.bundleIdentifier)

            let response = AppStreamStartedMessage(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                windows: startupResult.windows.sorted { $0.streamID < $1.streamID }
            )
            let responseMessage = try ControlMessage(type: .appStreamStarted, content: response)
            connection.send(content: responseMessage.serialize(), completion: .idempotent)

            pendingLightsOutSetup = false
            await endPendingAppStreamLightsOutSetup()
            MirageLogger.host("Started streaming \(app.name) with \(startupResult.windows.count) initial window(s)")
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
            }
            MirageLogger.error(.host, error: error, message: "Failed to handle select app: ")
        }
    }

    func handleCloseWindowRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection _: NWConnection
    )
    async {
        do {
            let request = try message.decode(CloseWindowRequestMessage.self)
            MirageLogger.host("Client \(client.name) requested to close window \(request.windowID)")

            let streamSession = activeStreams.first(where: { $0.window.id == request.windowID })
            let requestedWindow = streamSession?.window ??
                availableWindows.first(where: { $0.id == request.windowID })

            // Closing any app-stream window is treated as ending the app stream session.
            if let appSession = await appStreamManager.getSessionForWindow(request.windowID) {
                await endAppStream(bundleIdentifier: appSession.bundleIdentifier)
            } else if let streamSession {
                await stopStream(streamSession, minimizeWindow: false)
            }

            guard let requestedWindow else {
                MirageLogger.host("Window \(request.windowID) was not found for host close")
                return
            }

            guard let app = requestedWindow.application else {
                MirageLogger.host("Window \(request.windowID) has no app context after stream teardown")
                return
            }

            if closeAppWindow(windowID: request.windowID, app: app) {
                MirageLogger.host("Closed host window \(request.windowID)")
            } else {
                MirageLogger.host("Failed to close host window \(request.windowID)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle close window request: ")
        }
    }

    private func closeAppWindow(windowID: WindowID, app: MirageApplication) -> Bool {
        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            MirageLogger.host("Cannot close window \(windowID): process \(app.id) is no longer running")
            return false
        }

        let appElement = AXUIElementCreateApplication(app.id)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let axWindows = windowsRef as? [AXUIElement],
              !axWindows.isEmpty else {
            MirageLogger.host("AX windows query failed for \(windowID): AXError \(result.rawValue)")
            return false
        }

        guard let axWindow = axWindows.first(where: { axWindowMatchesWindowID($0, windowID: windowID) }) else {
            MirageLogger.host("AX window match failed for \(windowID) (count: \(axWindows.count))")
            return false
        }

        if performAXWindowClose(axWindow) {
            return true
        }

        MirageLogger.host("AX close action failed for window \(windowID)")
        return false
    }

    private func axWindowMatchesWindowID(_ axWindow: AXUIElement, windowID: WindowID) -> Bool {
        var cgWindowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(axWindow, &cgWindowID)
        guard result == .success else { return false }
        return WindowID(cgWindowID) == windowID
    }

    private func performAXWindowClose(_ axWindow: AXUIElement) -> Bool {
        var closeButtonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           let closeButtonRef,
           CFGetTypeID(closeButtonRef) == AXUIElementGetTypeID() {
            let closeButton = unsafeBitCast(closeButtonRef, to: AXUIElement.self)
            if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
                return true
            }
        }

        let closeAction = "AXClose" as CFString
        return AXUIElementPerformAction(axWindow, closeAction) == .success
    }

    func handleStreamPaused(_ message: ControlMessage, from client: MirageConnectedClient) async {
        do {
            let request = try message.decode(StreamPausedMessage.self)
            MirageLogger.host("Client \(client.name) paused stream \(request.streamID)")

            // Find the session and pause it
            if let session = await appStreamManager.getSessionForStreamID(request.streamID) {
                await appStreamManager.pauseStream(
                    bundleIdentifier: session.bundleIdentifier,
                    streamID: request.streamID
                )
                await applyClientFocusThrottle(streamID: request.streamID, isFocused: false)
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle stream paused: ")
        }
    }

    func handleStreamResumed(_ message: ControlMessage, from client: MirageConnectedClient) async {
        do {
            let request = try message.decode(StreamResumedMessage.self)
            MirageLogger.host("Client \(client.name) resumed stream \(request.streamID)")

            // Find the session and resume it
            if let session = await appStreamManager.getSessionForStreamID(request.streamID) {
                await appStreamManager.resumeStream(
                    bundleIdentifier: session.bundleIdentifier,
                    streamID: request.streamID
                )
                await applyClientFocusThrottle(streamID: request.streamID, isFocused: true)
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle stream resumed: ")
        }
    }

    private struct InitialAppWindowStartupResult {
        let windows: [AppStreamStartedMessage.AppStreamWindow]
        let failureSummary: String
    }

    private func startInitialAppWindowStreams(
        app: MirageInstalledApp,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize
    ) async -> InitialAppWindowStartupResult {
        let maxAttempts = 8
        var startedWindows: [AppStreamStartedMessage.AppStreamWindow] = []
        var failureNotes: [String] = []
        struct StartupFailureRecord {
            let windowID: WindowID
            let title: String
            let reason: String
            let attempt: Int
        }
        var latestFailureByWindow: [WindowID: StartupFailureRecord] = [:]
        let clientContext = findClientContext(clientID: client.id)

        for attempt in 1 ... maxAttempts {
            try? await refreshWindows()
            let matchingCandidates = availableWindows.filter { window in
                windowMatchesSelectedAppWindow(window, bundleIdentifier: app.bundleIdentifier)
            }
            let preferredCandidates = matchingCandidates.filter(isLikelyPrimaryAppStreamWindow)
            let candidates = (preferredCandidates.isEmpty ? matchingCandidates : preferredCandidates)
                .sorted(by: sortAppStreamCandidateWindows)

            if candidates.isEmpty {
                failureNotes.append("attempt \(attempt): no streamable windows found")
                if attempt < maxAttempts {
                    let retryDelay: Duration = attempt <= 3 ? .milliseconds(250) : .milliseconds(500)
                    try? await Task.sleep(for: retryDelay)
                }
                continue
            }

            for candidate in candidates {
                if startedWindows.contains(where: { $0.windowID == candidate.id }) { continue }
                do {
                    let startedWindow = try await attemptStartInitialAppWindowStream(
                        app: app,
                        candidateWindow: candidate,
                        client: client,
                        selectRequest: selectRequest,
                        targetFrameRate: targetFrameRate,
                        requestedDisplayResolution: requestedDisplayResolution
                    )
                    startedWindows.append(startedWindow)
                } catch {
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                    failureNotes.append("window \(candidate.id) attempt \(attempt): \(renderedDetail)")
                    latestFailureByWindow[candidate.id] = StartupFailureRecord(
                        windowID: candidate.id,
                        title: candidate.title ?? app.name,
                        reason: renderedDetail,
                        attempt: attempt
                    )
                    MirageLogger.error(
                        .host,
                        error: error,
                        message: "Failed initial app stream attempt for window \(candidate.id): "
                    )
                }
            }

            if !startedWindows.isEmpty {
                return InitialAppWindowStartupResult(
                    windows: startedWindows.sorted { $0.streamID < $1.streamID },
                    failureSummary: failureNotes.suffix(3).joined(separator: "; ")
                )
            }

            if attempt < maxAttempts {
                let retryDelay: Duration = attempt <= 3 ? .milliseconds(250) : .milliseconds(500)
                try? await Task.sleep(for: retryDelay)
            }
        }

        if let clientContext {
            for failure in latestFailureByWindow.values.sorted(by: { lhs, rhs in
                if lhs.attempt != rhs.attempt { return lhs.attempt < rhs.attempt }
                return lhs.windowID < rhs.windowID
            }) {
                await emitWindowStreamFailed(
                    to: clientContext,
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: failure.windowID,
                    title: failure.title,
                    reason: failure.reason
                )
            }
        }

        let summary = failureNotes.suffix(3).joined(separator: "; ")
        return InitialAppWindowStartupResult(
            windows: [],
            failureSummary: summary.isEmpty ? "no streamable windows became available" : summary
        )
    }

    private func attemptStartInitialAppWindowStream(
        app: MirageInstalledApp,
        candidateWindow: MirageWindow,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize
    ) async throws -> AppStreamStartedMessage.AppStreamWindow {
        let streamSession = try await startStream(
            for: candidateWindow,
            to: client,
            dataPort: selectRequest.dataPort,
            clientDisplayResolution: requestedDisplayResolution,
            clientScaleFactor: selectRequest.scaleFactor,
            keyFrameInterval: selectRequest.keyFrameInterval,
            streamScale: selectRequest.streamScale ?? 1.0,
            targetFrameRate: targetFrameRate,
            bitDepth: selectRequest.bitDepth,
            captureQueueDepth: selectRequest.captureQueueDepth,
            bitrate: selectRequest.bitrate,
            latencyMode: selectRequest.latencyMode ?? .auto,
            performanceMode: selectRequest.performanceMode ?? .standard,
            allowRuntimeQualityAdjustment: selectRequest.allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: selectRequest.lowLatencyHighResolutionCompressionBoost ?? true,
            disableResolutionCap: selectRequest.disableResolutionCap ?? false,
            audioConfiguration: selectRequest.audioConfiguration ?? .default
        )

        let resolvedWindow = streamSession.window
        let processID = resolvedWindow.application?.id ?? candidateWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
            windowID: resolvedWindow.id,
            processID: processID
        )

        await appStreamManager.addWindowToSession(
            bundleIdentifier: app.bundleIdentifier,
            windowID: resolvedWindow.id,
            streamID: streamSession.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height),
            isResizable: isResizable
        )

        return AppStreamStartedMessage.AppStreamWindow(
            streamID: streamSession.id,
            windowID: resolvedWindow.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height),
            isResizable: isResizable
        )
    }

    private func sortAppStreamCandidateWindows(_ lhs: MirageWindow, _ rhs: MirageWindow) -> Bool {
        if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
        if lhs.windowLayer != rhs.windowLayer { return lhs.windowLayer < rhs.windowLayer }

        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }

        return lhs.id < rhs.id
    }

    private func isLikelyPrimaryAppStreamWindow(_ window: MirageWindow) -> Bool {
        guard window.isOnScreen else { return false }
        guard window.windowLayer == 0 else { return false }
        guard window.frame.width >= 160, window.frame.height >= 120 else { return false }
        return true
    }

    private func sendAppSelectionError(
        over connection: NWConnection,
        code: ErrorMessage.ErrorCode,
        message: String
    ) {
        let error = ErrorMessage(code: code, message: message)
        guard let response = try? ControlMessage(type: .error, content: error) else { return }
        connection.send(content: response.serialize(), completion: .idempotent)
    }

    private func applyClientFocusThrottle(streamID: StreamID, isFocused: Bool) async {
        guard let context = streamsByID[streamID] else {
            pausedStreamBaselineFrameRateByStreamID.removeValue(forKey: streamID)
            return
        }

        if isFocused {
            let restoreFrameRate: Int
            if let savedFrameRate = pausedStreamBaselineFrameRateByStreamID.removeValue(forKey: streamID) {
                restoreFrameRate = savedFrameRate
            } else {
                restoreFrameRate = await context.getTargetFrameRate()
            }
            do {
                try await context.updateFrameRate(max(1, restoreFrameRate))
                await context.requestKeyframe()
                MirageLogger.host("Stream \(streamID) focused - restored to \(max(1, restoreFrameRate)) fps")
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed restoring stream \(streamID) frame rate: ")
            }
            return
        }

        if pausedStreamBaselineFrameRateByStreamID[streamID] == nil {
            pausedStreamBaselineFrameRateByStreamID[streamID] = await context.getTargetFrameRate()
        }

        do {
            try await context.updateFrameRate(1)
            MirageLogger.host("Stream \(streamID) unfocused - throttled to 1 fps")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed throttling stream \(streamID): ")
        }
    }

    func suspendAppListRequestsForDesktopStream() async {
        if appListRequestTask != nil { MirageLogger.host("Cancelling app list request for desktop streaming") }
        appListRequestTask?.cancel()
        appListRequestTask = nil
        await appStreamManager.cancelAppListScans()
    }

    func resumePendingAppListRequestIfNeeded() {
        guard desktopStreamContext == nil else { return }
        sendPendingAppListRequestIfPossible()
    }

    private func updatePendingAppListRequest(
        clientID: UUID,
        requestedIcons: Bool,
        requestedForceRefresh: Bool
    ) {
        if var pending = pendingAppListRequest, pending.clientID == clientID {
            pending.requestedIcons = pending.requestedIcons || requestedIcons
            pending.requestedForceRefresh = pending.requestedForceRefresh || requestedForceRefresh
            pendingAppListRequest = pending
            return
        }
        pendingAppListRequest = PendingAppListRequest(
            clientID: clientID,
            requestedIcons: requestedIcons,
            requestedForceRefresh: requestedForceRefresh
        )
    }

    private func sendPendingAppListRequestIfPossible() {
        guard desktopStreamContext == nil else { return }
        guard let pending = pendingAppListRequest else { return }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingAppListRequest = nil
            return
        }

        appListRequestTask?.cancel()
        let includeIcons = pending.requestedIcons && sessionState == .active
        let forceRefresh = pending.requestedForceRefresh
        if pending.requestedIcons, !includeIcons {
            MirageLogger.host("Session is \(sessionState); responding with app list without icons")
        }
        let clientID = pending.clientID
        let token = UUID()
        appListRequestToken = token

        appListRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await pruneOrphanedAppSessions()

            let apps = await appStreamManager.getInstalledApps(
                includeIcons: includeIcons,
                forceRefresh: forceRefresh
            )
            if Task.isCancelled { return }

            do {
                let response = AppListMessage(apps: apps)
                try await clientContext.send(.appList, content: response)
                MirageLogger.host("Sent \(apps.count) apps to \(clientContext.client.name)")
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to handle app list request: ")
                return
            }

            if Task.isCancelled { return }
            if appListRequestToken == token, pendingAppListRequest?.clientID == clientID {
                pendingAppListRequest = nil
            }
        }
    }

    private func pruneOrphanedAppSessions() async {
        let connectedClientIDs = Set(connectedClients.map(\.id))
        await appStreamManager.endSessionsNotOwned(by: connectedClientIDs)
    }
}

#endif
