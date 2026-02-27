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
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    enum InitialAppWindowStartupDecision: Equatable, Sendable {
        case continueStreaming
        case abortSession
    }

    nonisolated static func initialAppWindowStartupDecision(
        startedWindowCount: Int
    ) -> InitialAppWindowStartupDecision {
        startedWindowCount > 0 ? .continueStreaming : .abortSession
    }

    nonisolated static func appWindowStartupBatchRanges(
        totalCount: Int,
        maxConcurrentWindowStarts: Int
    ) -> [Range<Int>] {
        guard totalCount > 0 else { return [] }
        let clampedWidth = max(1, maxConcurrentWindowStarts)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity((totalCount + clampedWidth - 1) / clampedWidth)
        var lowerBound = 0
        while lowerBound < totalCount {
            let upperBound = min(lowerBound + clampedWidth, totalCount)
            ranges.append(lowerBound ..< upperBound)
            lowerBound = upperBound
        }
        return ranges
    }

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
            let maxVisibleSlots = resolvedMaxVisibleAppWindowSlots(request.maxConcurrentVisibleWindows)
            let sharedBitrateBudget = resolvedAppSessionBitrateBudget(requestedBitrate: request.bitrate)
            let bitrateAllocationPolicy = request.bitrateAllocationPolicy ?? .prioritizeActiveWindow
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Performance mode: \(performanceMode.displayName)")
            MirageLogger
                .host(
                    "App stream slot cap: \(maxVisibleSlots), shared bitrate budget: \(sharedBitrateBudget.map { "\($0) bps" } ?? "none"), allocationPolicy: \(bitrateAllocationPolicy.rawValue)"
                )

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
                requestedClientScaleFactor: request.scaleFactor,
                maxVisibleSlots: maxVisibleSlots,
                bitrateBudgetBps: sharedBitrateBudget,
                bitrateAllocationPolicy: bitrateAllocationPolicy
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
                requestedDisplayResolution: requestedDisplayResolution,
                maxVisibleSlots: maxVisibleSlots
            )
            let startupDecision = Self.initialAppWindowStartupDecision(
                startedWindowCount: startupResult.windows.count
            )
            guard startupDecision == .continueStreaming else {
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
            await sendAppWindowInventoryUpdate(bundleIdentifier: app.bundleIdentifier, clientID: client.id)
            await startAppStreamGovernorsIfNeeded()
            await recomputeAppSessionBitrateBudget(bundleIdentifier: app.bundleIdentifier, reason: "appStreamStarted")

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

            let streamSession = activeStreamIDByWindowID[request.windowID].flatMap { activeSessionByStreamID[$0] }
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

    func handleAppWindowSwapRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        do {
            let request = try message.decode(AppWindowSwapRequestMessage.self)
            let result = await performAppWindowSwap(
                bundleIdentifier: request.bundleIdentifier,
                targetSlotStreamID: request.targetSlotStreamID,
                targetWindowID: request.targetWindowID,
                clientID: client.id
            )
            if let response = try? ControlMessage(type: .appWindowSwapResult, content: result) {
                connection.send(content: response.serialize(), completion: .idempotent)
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle app window swap request: ")
            let fallback = AppWindowSwapResultMessage(
                bundleIdentifier: "",
                targetSlotStreamID: 0,
                windowID: 0,
                success: false,
                reason: error.localizedDescription
            )
            if let response = try? ControlMessage(type: .appWindowSwapResult, content: fallback) {
                connection.send(content: response.serialize(), completion: .idempotent)
            }
        }
    }

    private func performAppWindowSwap(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID,
        clientID: UUID
    ) async -> AppWindowSwapResultMessage {
        let failure: (String) -> AppWindowSwapResultMessage = { reason in
            AppWindowSwapResultMessage(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                windowID: targetWindowID,
                success: false,
                reason: reason
            )
        }

        guard let appSession = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else {
            return failure("App session not found")
        }
        guard appSession.clientID == clientID else {
            return failure("Swap request client does not own this app session")
        }
        guard let currentWindowID = await appStreamManager.windowIDForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: targetSlotStreamID
        ) else {
            return failure("Target slot stream is not active")
        }
        guard let hiddenInfo = await appStreamManager.hiddenWindowInfo(
            bundleIdentifier: bundleIdentifier,
            windowID: targetWindowID
        ) else {
            return failure("Target window is not in hidden inventory")
        }
        guard let streamSession = activeSessionByStreamID[targetSlotStreamID],
              let context = streamsByID[targetSlotStreamID] else {
            return failure("Target slot stream context is unavailable")
        }
        let previousWindowInfo = appSession.windowStreams[currentWindowID]
        guard let virtualDisplayState = getVirtualDisplayState(streamID: targetSlotStreamID) else {
            return failure("Target slot stream does not have virtual-display state")
        }
        guard let clientContext = findClientContext(clientID: clientID) else {
            return failure("Client context unavailable")
        }

        if currentWindowID == targetWindowID {
            return AppWindowSwapResultMessage(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                windowID: targetWindowID,
                success: true,
                reason: nil
            )
        }

        let resolvedSpaceID = CGVirtualDisplayBridge.getSpaceForDisplay(virtualDisplayState.displayID)
        guard resolvedSpaceID != 0 else {
            return failure("Unable to resolve target display space for slot")
        }

        let oldOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: targetSlotStreamID,
            windowID: currentWindowID,
            displayID: virtualDisplayState.displayID,
            generation: virtualDisplayState.generation
        )
        let newGeneration = virtualDisplayState.generation &+ 1
        let newOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: targetSlotStreamID,
            windowID: targetWindowID,
            displayID: virtualDisplayState.displayID,
            generation: newGeneration
        )

        do {
            try await WindowSpaceManager.shared.restoreWindow(
                currentWindowID,
                expectedOwner: oldOwner
            )
        } catch {
            return failure("Failed to release previous slot window: \(error.localizedDescription)")
        }

        do {
            try await WindowSpaceManager.shared.moveWindow(
                targetWindowID,
                toSpaceID: resolvedSpaceID,
                displayID: virtualDisplayState.displayID,
                displayBounds: virtualDisplayState.bounds,
                targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                owner: newOwner
            )
        } catch {
            // Fail closed: attempt to restore prior slot binding before returning error.
            do {
                try await WindowSpaceManager.shared.moveWindow(
                    currentWindowID,
                    toSpaceID: resolvedSpaceID,
                    displayID: virtualDisplayState.displayID,
                    displayBounds: virtualDisplayState.bounds,
                    targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                    owner: oldOwner
                )
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to restore prior slot binding after swap failure: "
                )
            }
            return failure("Failed to bind requested hidden window into slot: \(error.localizedDescription)")
        }

        let targetFrame = currentWindowFrame(for: targetWindowID) ?? CGRect(
            x: virtualDisplayState.bounds.origin.x,
            y: virtualDisplayState.bounds.origin.y,
            width: CGFloat(max(1, hiddenInfo.width)),
            height: CGFloat(max(1, hiddenInfo.height))
        )
        let targetWindow = MirageWindow(
            id: targetWindowID,
            title: hiddenInfo.title,
            application: activeSessionByStreamID[targetSlotStreamID]?.window.application,
            frame: targetFrame,
            isOnScreen: true,
            windowLayer: 0
        )

        registerActiveStreamSession(
            MirageStreamSession(
                id: targetSlotStreamID,
                window: targetWindow,
                client: streamSession.client
            )
        )
        inputStreamCacheActor.set(targetSlotStreamID, window: targetWindow, client: streamSession.client)
        clearVirtualDisplayState(windowID: currentWindowID)
        setVirtualDisplayState(
            windowID: targetWindowID,
            state: WindowVirtualDisplayState(
                streamID: targetSlotStreamID,
                displayID: virtualDisplayState.displayID,
                generation: newGeneration,
                bounds: virtualDisplayState.bounds,
                targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                captureSourceRect: virtualDisplayState.captureSourceRect,
                visiblePixelResolution: virtualDisplayState.visiblePixelResolution,
                scaleFactor: virtualDisplayState.scaleFactor,
                pixelResolution: virtualDisplayState.pixelResolution,
                clientScaleFactor: virtualDisplayState.clientScaleFactor
            )
        )
        await context.updateWindowBinding(windowID: targetWindowID, ownerGeneration: newGeneration)

        let processID = targetWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(windowID: targetWindowID, processID: processID)
        _ = await appStreamManager.replaceVisibleWindowForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: targetSlotStreamID,
            newWindowID: targetWindowID,
            title: targetWindow.title,
            width: Int(targetWindow.frame.width),
            height: Int(targetWindow.frame.height),
            isResizable: isResizable
        )
        await appStreamManager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: currentWindowID,
            title: previousWindowInfo?.title ?? streamSession.window.title,
            width: previousWindowInfo?.width ?? Int(max(1, streamSession.window.frame.width)),
            height: previousWindowInfo?.height ?? Int(max(1, streamSession.window.frame.height)),
            isResizable: previousWindowInfo?.isResizable ?? true
        )

        do {
            let encodedDimensions = await context.getEncodedDimensions()
            let targetFrameRate = await context.getTargetFrameRate()
            let codec = await context.getCodec()
            let dimensionToken = await context.getDimensionToken()
            let fallbackMin = fallbackMinimumSize(for: targetWindow.frame)
            let minWidth = Int(minimumSizesByWindowID[targetWindowID]?.width ?? CGFloat(fallbackMin.minWidth))
            let minHeight = Int(minimumSizesByWindowID[targetWindowID]?.height ?? CGFloat(fallbackMin.minHeight))
            let started = StreamStartedMessage(
                streamID: targetSlotStreamID,
                windowID: targetWindowID,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: targetFrameRate,
                codec: codec,
                minWidth: minWidth,
                minHeight: minHeight,
                dimensionToken: dimensionToken
            )
            try await clientContext.send(.streamStarted, content: started)
        } catch {
            return failure("Swap applied but failed to notify client stream metadata: \(error.localizedDescription)")
        }

        await context.requestKeyframe()
        await markAppStreamInteraction(streamID: targetSlotStreamID, reason: "slot swap")
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleIdentifier, clientID: clientID)
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "slot swap")

        return AppWindowSwapResultMessage(
            bundleIdentifier: bundleIdentifier,
            targetSlotStreamID: targetSlotStreamID,
            windowID: targetWindowID,
            success: true,
            reason: nil
        )
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

    private struct InitialAppWindowStartupResult {
        let windows: [AppStreamStartedMessage.AppStreamWindow]
        let failureSummary: String
    }

    private struct InitialStartedAppWindow: Sendable, Equatable {
        let streamID: StreamID
        let windowID: WindowID
        let title: String?
        let width: Int
        let height: Int
        let isResizable: Bool

        var asWireWindow: AppStreamStartedMessage.AppStreamWindow {
            AppStreamStartedMessage.AppStreamWindow(
                streamID: streamID,
                windowID: windowID,
                title: title,
                width: width,
                height: height,
                isResizable: isResizable
            )
        }
    }

    private struct InitialAppWindowStartAttemptResult: Sendable {
        let startedWindow: InitialStartedAppWindow?
        let failureNotes: [String]
    }

    private func startInitialAppWindowStreams(
        app: MirageInstalledApp,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        maxVisibleSlots: Int
    ) async -> InitialAppWindowStartupResult {
        let maxDiscoveryAttempts = 4
        let maxAttemptsPerWindow = 3
        let maxConcurrentWindowStarts = 2
        let perWindowRetryBackoff: [Duration] = [
            .milliseconds(350),
            .seconds(1),
            .seconds(2),
        ]
        let normalizedBundleID = app.bundleIdentifier.lowercased()
        var startedWindows: [AppStreamStartedMessage.AppStreamWindow] = []
        var failureNotes: [String] = []
        let clientContext = findClientContext(clientID: client.id)
        var primaryCandidates: [AppStreamWindowCandidate] = []

        for discoveryAttempt in 1 ... maxDiscoveryAttempts {
            do {
                let catalog = try await AppStreamWindowCatalog.catalog(for: [app.bundleIdentifier])
                let allCandidates = (catalog[normalizedBundleID] ?? [])
                    .sorted { lhs, rhs in
                        sortAppStreamCandidateWindows(lhs.window, rhs.window)
                    }
                let auxiliaryCount = allCandidates.filter { $0.classification == .auxiliary }.count
                if auxiliaryCount > 0 {
                    MirageLogger.host(
                        "Initial startup detected \(auxiliaryCount) auxiliary parent-coupled windows for \(app.bundleIdentifier)"
                    )
                }
                primaryCandidates = allCandidates.filter { $0.classification == .primary }
                if !primaryCandidates.isEmpty { break }
                failureNotes.append("discovery \(discoveryAttempt): no streamable primary windows found")
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append("discovery \(discoveryAttempt): \(renderedDetail)")
                MirageLogger.error(.host, error: error, message: "Failed app-stream window discovery: ")
            }

            if discoveryAttempt < maxDiscoveryAttempts {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        if primaryCandidates.isEmpty {
            let summary = failureNotes.suffix(3).joined(separator: "; ")
            return InitialAppWindowStartupResult(
                windows: [],
                failureSummary: summary.isEmpty ? "no streamable primary windows became available" : summary
            )
        }

        let bindingPlan: AppWindowBindingPlan
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let liveWindows = content.windows.compactMap { window -> MirageWindow? in
                guard let app = window.owningApplication else { return nil }
                return MirageWindow(
                    id: WindowID(window.windowID),
                    title: window.title,
                    application: MirageApplication(
                        id: app.processID,
                        bundleIdentifier: app.bundleIdentifier,
                        name: app.applicationName
                    ),
                    frame: window.frame,
                    isOnScreen: window.isOnScreen,
                    windowLayer: window.windowLayer
                )
            }
            bindingPlan = AppWindowBindingPlanner.plan(
                candidates: primaryCandidates,
                liveWindows: liveWindows,
                claimedWindowIDs: Set(activeStreamIDByWindowID.keys)
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedDetail = detail.isEmpty ? String(describing: error) : detail
            failureNotes.append("binding plan snapshot failed: \(renderedDetail)")
            bindingPlan = AppWindowBindingPlan(
                resolvedBindings: [],
                unresolvedCandidates: primaryCandidates
            )
        }

        let remappedWindowCount = bindingPlan.resolvedBindings.reduce(into: 0) { partialResult, binding in
            if binding.candidate.window.id != binding.resolvedWindow.id {
                partialResult += 1
            }
        }
        if remappedWindowCount > 0 {
            MirageLogger.host(
                "Initial app-stream startup remapped \(remappedWindowCount) window(s) for \(app.bundleIdentifier)"
            )
        }

        for candidate in bindingPlan.unresolvedCandidates {
            let reason = "no unclaimed live window match in startup wave"
            failureNotes.append("window \(candidate.window.id): \(reason)")
            let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                bundleID: app.bundleIdentifier,
                windowID: candidate.window.id,
                retryable: true,
                reason: reason
            )
            switch failureDisposition {
            case let .retryScheduled(retryAttempt, retryAt):
                MirageLogger.host(
                    "Initial app-stream startup retry scheduled for \(candidate.window.id) attempt \(retryAttempt) at \(retryAt) (\(candidate.logMetadata))"
                )
            case .terminal:
                if let clientContext {
                    await emitWindowStreamFailed(
                        to: clientContext,
                        bundleIdentifier: app.bundleIdentifier,
                        windowID: candidate.window.id,
                        title: initialStreamFailureTitle(for: candidate, appName: app.name),
                        reason: reason
                    )
                }
                MirageLogger.host(
                    "Initial app-stream startup failed permanently for \(candidate.window.id): \(reason) (\(candidate.logMetadata))"
                )
            case .suppressed:
                break
            }
        }

        let clampedMaxVisibleSlots = max(1, maxVisibleSlots)
        let visibleBindings: [(slotIndex: Int, binding: ResolvedAppWindowBinding)] = Array(
            bindingPlan.resolvedBindings
                .prefix(clampedMaxVisibleSlots)
                .enumerated()
                .map { index, binding in
                    (slotIndex: index, binding: binding)
                }
        )
        let overflowBindings = Array(bindingPlan.resolvedBindings.dropFirst(clampedMaxVisibleSlots))
        var startupBitratePerVisibleWindow: Int?
        if !visibleBindings.isEmpty {
            let visibleCount = max(1, visibleBindings.count)
            let perStreamBitrateCap = Self.appStreamPerStreamBitrateCap(visibleStreamCount: visibleCount)
            let sharedBudgetBps = await appStreamManager.sharedBitrateBudget(bundleIdentifier: app.bundleIdentifier)
                ?? resolvedAppSessionBitrateBudget(requestedBitrate: selectRequest.bitrate)
            if let sharedBudgetBps {
                let perVisibleBitrate = max(1_000_000, sharedBudgetBps / visibleCount)
                startupBitratePerVisibleWindow = min(perVisibleBitrate, perStreamBitrateCap)
            } else {
                if let requestedBitrate = selectRequest.bitrate {
                    startupBitratePerVisibleWindow = min(max(1_000_000, requestedBitrate), perStreamBitrateCap)
                } else {
                    startupBitratePerVisibleWindow = perStreamBitrateCap == Int.max ? nil : perStreamBitrateCap
                }
            }
        }
        if !overflowBindings.isEmpty {
            for binding in overflowBindings {
                let resolved = binding.resolvedWindow
                let processID = resolved.application?.id ?? binding.candidate.window.application?.id ?? 0
                let isResizable = appStreamManager.checkWindowResizability(
                    windowID: resolved.id,
                    processID: processID
                )
                await appStreamManager.upsertHiddenWindow(
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: resolved.id,
                    title: resolved.title,
                    width: Int(resolved.frame.width),
                    height: Int(resolved.frame.height),
                    isResizable: isResizable
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: binding.candidate.window.id
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: resolved.id
                )
            }
            MirageLogger
                .host(
                    "Initial app-stream startup queued \(overflowBindings.count) hidden window(s) for \(app.bundleIdentifier)"
                )
        }

        let startupBatchRanges = Self.appWindowStartupBatchRanges(
            totalCount: visibleBindings.count,
            maxConcurrentWindowStarts: maxConcurrentWindowStarts
        )
        var startedWindowIDs: Set<WindowID> = []
        var startedStreamIDs: Set<StreamID> = []
        for batchRange in startupBatchRanges {
            let batch = Array(visibleBindings[batchRange])
            let batchTasks = batch.map { binding in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return InitialAppWindowStartAttemptResult(
                            startedWindow: nil,
                            failureNotes: ["startup cancelled: host service released"]
                        )
                    }
                    return await self.startInitialAppWindowBinding(
                        app: app,
                        binding: binding.binding,
                        preferredSlotIndex: binding.slotIndex,
                        client: client,
                        selectRequest: selectRequest,
                        targetFrameRate: targetFrameRate,
                        requestedDisplayResolution: requestedDisplayResolution,
                        maxAttemptsPerWindow: maxAttemptsPerWindow,
                        perWindowRetryBackoff: perWindowRetryBackoff,
                        startupBitratePerVisibleWindow: startupBitratePerVisibleWindow,
                        clientContext: clientContext
                    )
                }
            }
            var batchResults: [InitialAppWindowStartAttemptResult] = []
            batchResults.reserveCapacity(batchTasks.count)
            for task in batchTasks {
                batchResults.append(await task.value)
            }

            for result in batchResults {
                failureNotes.append(contentsOf: result.failureNotes)
                guard let startedWindow = result.startedWindow else { continue }
                let insertedWindow = startedWindowIDs.insert(startedWindow.windowID).inserted
                let insertedStream = startedStreamIDs.insert(startedWindow.streamID).inserted
                if !insertedWindow || !insertedStream {
                    continue
                }
                startedWindows.append(startedWindow.asWireWindow)
            }
        }

        let summary = failureNotes.suffix(3).joined(separator: "; ")
        return InitialAppWindowStartupResult(
            windows: startedWindows.sorted { $0.streamID < $1.streamID },
            failureSummary: summary.isEmpty ? "no streamable primary windows became available" : summary
        )
    }

    private func startInitialAppWindowBinding(
        app: MirageInstalledApp,
        binding: ResolvedAppWindowBinding,
        preferredSlotIndex: Int,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        maxAttemptsPerWindow: Int,
        perWindowRetryBackoff: [Duration],
        startupBitratePerVisibleWindow: Int?,
        clientContext: ClientContext?
    ) async -> InitialAppWindowStartAttemptResult {
        var failureNotes: [String] = []

        for attempt in 1 ... maxAttemptsPerWindow {
            do {
                let startedWindow = try await attemptStartInitialAppWindowStream(
                    app: app,
                    startupCandidate: binding.candidate,
                    preferredWindow: binding.resolvedWindow,
                    preferredSlotIndex: preferredSlotIndex,
                    client: client,
                    selectRequest: selectRequest,
                    targetFrameRate: targetFrameRate,
                    requestedDisplayResolution: requestedDisplayResolution,
                    requestedBitrateOverride: startupBitratePerVisibleWindow
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: binding.candidate.window.id
                )
                await appStreamManager.noteWindowStartupSucceeded(
                    bundleID: app.bundleIdentifier,
                    windowID: startedWindow.windowID
                )
                return InitialAppWindowStartAttemptResult(
                    startedWindow: InitialStartedAppWindow(
                        streamID: startedWindow.streamID,
                        windowID: startedWindow.windowID,
                        title: startedWindow.title,
                        width: startedWindow.width,
                        height: startedWindow.height,
                        isResizable: startedWindow.isResizable
                    ),
                    failureNotes: failureNotes
                )
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append("window \(binding.candidate.window.id) attempt \(attempt): \(renderedDetail)")

                let retryable = AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error)
                let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                    bundleID: app.bundleIdentifier,
                    windowID: binding.candidate.window.id,
                    retryable: retryable,
                    reason: renderedDetail
                )
                let shouldMoveToHiddenInventory = AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error)

                switch failureDisposition {
                case let .retryScheduled(retryAttempt, retryAt):
                    MirageLogger.host(
                        "Initial app-stream startup retry scheduled for \(binding.candidate.window.id) attempt \(retryAttempt) at \(retryAt) (\(binding.candidate.logMetadata))"
                    )
                case .terminal:
                    if shouldMoveToHiddenInventory {
                        let resolved = binding.resolvedWindow
                        let processID = resolved.application?.id ?? binding.candidate.window.application?.id ?? 0
                        let isResizable = appStreamManager.checkWindowResizability(
                            windowID: resolved.id,
                            processID: processID
                        )
                        await appStreamManager.upsertHiddenWindow(
                            bundleIdentifier: app.bundleIdentifier,
                            windowID: resolved.id,
                            title: resolved.title,
                            width: Int(resolved.frame.width),
                            height: Int(resolved.frame.height),
                            isResizable: isResizable
                        )
                        await appStreamManager.noteWindowStartupSucceeded(
                            bundleID: app.bundleIdentifier,
                            windowID: binding.candidate.window.id
                        )
                        await appStreamManager.noteWindowStartupSucceeded(
                            bundleID: app.bundleIdentifier,
                            windowID: resolved.id
                        )
                        MirageLogger.host(
                            "Initial app-stream startup moved window \(resolved.id) to hidden inventory after non-retryable startup failure: \(renderedDetail) (\(binding.candidate.logMetadata))"
                        )
                    } else {
                        if let clientContext {
                            await emitWindowStreamFailed(
                                to: clientContext,
                                bundleIdentifier: app.bundleIdentifier,
                                windowID: binding.candidate.window.id,
                                title: initialStreamFailureTitle(for: binding.candidate, appName: app.name),
                                reason: renderedDetail
                            )
                        }
                        MirageLogger.host(
                            "Initial app-stream startup failed permanently for \(binding.candidate.window.id): \(renderedDetail) (\(binding.candidate.logMetadata))"
                        )
                    }
                case .suppressed:
                    break
                }

                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed initial app stream attempt for window \(binding.candidate.window.id): "
                )

                guard retryable, attempt < maxAttemptsPerWindow else { break }
                guard case .retryScheduled = failureDisposition else { break }
                let backoffIndex = min(attempt - 1, perWindowRetryBackoff.count - 1)
                try? await Task.sleep(for: perWindowRetryBackoff[backoffIndex])
            }
        }

        return InitialAppWindowStartAttemptResult(startedWindow: nil, failureNotes: failureNotes)
    }

    private func attemptStartInitialAppWindowStream(
        app: MirageInstalledApp,
        startupCandidate: AppStreamWindowCandidate,
        preferredWindow: MirageWindow,
        preferredSlotIndex: Int,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        requestedBitrateOverride: Int?
    ) async throws -> AppStreamStartedMessage.AppStreamWindow {
        let streamSession = try await startStream(
            for: preferredWindow,
            to: client,
            dataPort: selectRequest.dataPort,
            clientDisplayResolution: requestedDisplayResolution,
            clientScaleFactor: selectRequest.scaleFactor,
            keyFrameInterval: selectRequest.keyFrameInterval,
            streamScale: selectRequest.streamScale ?? 1.0,
            targetFrameRate: targetFrameRate,
            bitDepth: selectRequest.bitDepth,
            captureQueueDepth: selectRequest.captureQueueDepth,
            bitrate: requestedBitrateOverride ?? selectRequest.bitrate,
            latencyMode: selectRequest.latencyMode ?? .auto,
            performanceMode: selectRequest.performanceMode ?? .standard,
            allowRuntimeQualityAdjustment: selectRequest.allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: selectRequest.lowLatencyHighResolutionCompressionBoost ?? true,
            disableResolutionCap: selectRequest.disableResolutionCap ?? false,
            allowBestEffortRemap: false,
            audioConfiguration: selectRequest.audioConfiguration ?? .default
        )

        let resolvedWindow = streamSession.window
        let processID = resolvedWindow.application?.id ?? preferredWindow.application?.id ?? startupCandidate.window.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
            windowID: resolvedWindow.id,
            processID: processID
        )

        if let existingStreamID = await appStreamManager.streamIDForWindow(
            bundleIdentifier: app.bundleIdentifier,
            windowID: resolvedWindow.id
        ), existingStreamID != streamSession.id {
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindow.id,
                existingStreamID: existingStreamID
            )
        }

        guard await appStreamManager.addWindowToSession(
            bundleIdentifier: app.bundleIdentifier,
            windowID: resolvedWindow.id,
            streamID: streamSession.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height),
            isResizable: isResizable,
            slotIndex: preferredSlotIndex
        ) != nil else {
            let existingStreamID = await appStreamManager.streamIDForWindow(
                bundleIdentifier: app.bundleIdentifier,
                windowID: resolvedWindow.id
            )
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            if let existingStreamID {
                throw WindowStreamStartError.windowAlreadyBound(
                    windowID: resolvedWindow.id,
                    existingStreamID: existingStreamID
                )
            }
            throw MirageError.protocolError(
                "Failed to bind startup window \(resolvedWindow.id) into slot \(preferredSlotIndex)"
            )
        }

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

    private func initialStreamFailureTitle(for candidate: AppStreamWindowCandidate, appName: String) -> String {
        if let title = candidate.window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "\(appName) window #\(candidate.window.id)"
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
