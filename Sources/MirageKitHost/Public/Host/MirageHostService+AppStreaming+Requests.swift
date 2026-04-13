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
import CryptoKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    private enum ExistingSessionWindowStartResult {
        case success(WindowAddedToStreamMessage)
        case failure(String)
    }

    enum InitialAppWindowStartupDecision: Equatable, Sendable {
        case continueStreaming
        case abortSession
    }

    enum ExistingSessionSelectDecision: Equatable, Sendable {
        case allowExpansion
        case rejectOtherClientOwner
        case rejectSessionNotStreaming
        case rejectVisibleSlotCapReached
    }

    enum AppListRequestDeferralTransition: Equatable, Sendable {
        case remainIdle
        case beginDeferral
        case remainDeferred
        case resumeDeferred
    }

    struct WindowStreamingPreparationPlan: Equatable, Sendable {
        let shouldRestoreWindow: Bool
        let shouldExitFullScreen: Bool
        let settleDelayMilliseconds: Int
    }

    nonisolated static func initialAppWindowStartupDecision(
        startedWindowCount: Int
    ) -> InitialAppWindowStartupDecision {
        startedWindowCount > 0 ? .continueStreaming : .abortSession
    }

    nonisolated static func existingSessionSelectDecision(
        sessionClientID: UUID,
        requestClientID: UUID,
        sessionState: AppStreamState,
        hasVisibleSlotCapacity: Bool
    ) -> ExistingSessionSelectDecision {
        guard sessionClientID == requestClientID else { return .rejectOtherClientOwner }
        guard sessionState == .streaming else { return .rejectSessionNotStreaming }
        guard hasVisibleSlotCapacity else { return .rejectVisibleSlotCapReached }
        return .allowExpansion
    }

    nonisolated static func shouldDeferAppListRequestsForInteractiveWorkload(
        hasActiveAppStreams: Bool,
        hasDesktopStream: Bool,
        hasPendingAppStreamStart: Bool,
        hasPendingDesktopStreamStart: Bool
    ) -> Bool {
        hasActiveAppStreams ||
            hasDesktopStream ||
            hasPendingAppStreamStart ||
            hasPendingDesktopStreamStart
    }

    nonisolated static func appListRequestDeferralTransition(
        wasDeferred: Bool,
        shouldDefer: Bool
    ) -> AppListRequestDeferralTransition {
        if shouldDefer {
            return wasDeferred ? .remainDeferred : .beginDeferral
        }
        return wasDeferred ? .resumeDeferred : .remainIdle
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

    nonisolated static func windowStreamingPreparationPlan(
        isOnScreen: Bool,
        isFullScreen: Bool
    ) -> WindowStreamingPreparationPlan {
        let shouldRestoreWindow = !isOnScreen
        let shouldExitFullScreen = isFullScreen
        let activationSettleDelayMilliseconds = 150
        let settleDelayMilliseconds: Int = switch (shouldRestoreWindow, shouldExitFullScreen) {
        case (true, true):
            350
        case (true, false), (false, true):
            250
        case (false, false):
            activationSettleDelayMilliseconds
        }

        return WindowStreamingPreparationPlan(
            shouldRestoreWindow: shouldRestoreWindow,
            shouldExitFullScreen: shouldExitFullScreen,
            settleDelayMilliseconds: settleDelayMilliseconds
        )
    }

    private func prepareWindowForStreamingIfNeeded(
        _ window: MirageWindow,
        reason: String
    ) async {
        let plan = Self.windowStreamingPreparationPlan(
            isOnScreen: window.isOnScreen,
            isFullScreen: WindowManager.isWindowFullScreen(window.id)
        )

        let didRestore = plan.shouldRestoreWindow
            ? WindowManager.restoreWindow(window.id)
            : false
        let didExitFullScreen = plan.shouldExitFullScreen
            ? WindowManager.exitFullScreen(window.id)
            : false
        activateWindow(window)
        if plan.settleDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(plan.settleDelayMilliseconds))
        }
        MirageLogger.host(
            "Prepared window \(window.id) for streaming (\(reason), restored=\(didRestore), exitedFullScreen=\(didExitFullScreen))"
        )
    }

    nonisolated static func initialAppWindowDiscoveryRetryDelay(
        afterAttempt attempt: Int
    ) -> Duration {
        let backoffSchedule: [Duration] = [
            .milliseconds(250),
            .milliseconds(350),
            .milliseconds(500),
            .milliseconds(750),
            .seconds(1),
        ]
        let normalizedAttempt = max(1, attempt)
        let index = min(normalizedAttempt - 1, backoffSchedule.count - 1)
        return backoffSchedule[index]
    }

    nonisolated static func shouldRequestNewAppWindowOnInitialDiscovery(
        discoveryAttempt: Int,
        newWindowRequestAttempts: Int
    ) -> Bool {
        let requestSchedule = [2, 5, 8, 11]
        guard newWindowRequestAttempts < requestSchedule.count else { return false }
        return discoveryAttempt >= requestSchedule[newWindowRequestAttempts]
    }

    nonisolated static func standaloneAuxiliaryFallbackCandidates(
        from candidates: [AppStreamWindowCandidate]
    ) -> [AppStreamWindowCandidate] {
        candidates
            .filter { candidate in
                candidate.classification == .auxiliary &&
                    candidate.parentWindowID == nil &&
                    candidate.window.isOnScreen &&
                    (candidate.isFocused || candidate.isMain)
            }
            .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
    }

    nonisolated static func initialAppWindowSlotRetryDelay(
        afterAttempt attempt: Int
    ) -> Duration {
        let backoffSchedule: [Duration] = [
            .milliseconds(350),
            .milliseconds(750),
            .seconds(1),
            .seconds(1),
        ]
        let normalizedAttempt = max(1, attempt)
        let index = min(normalizedAttempt - 1, backoffSchedule.count - 1)
        return backoffSchedule[index]
    }

    nonisolated static func resolveInitialAppWindowStartupBinding(
        candidates: [AppStreamWindowCandidate],
        liveWindows: [MirageWindow],
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>
    ) -> ResolvedAppWindowBinding? {
        let orderedCandidates = orderedLifecycleStartupCandidates(
            from: candidates,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs,
            preferredWindowID: preferredWindowID,
            deprioritizedWindowIDs: deprioritizedWindowIDs,
            excludedWindowIDs: excludedWindowIDs
        )
        guard !orderedCandidates.isEmpty else { return nil }

        let unavailableWindowIDs = visibleWindowIDs.union(claimedWindowIDs)
        let bindingPlan = AppWindowBindingPlanner.plan(
            candidates: orderedCandidates,
            liveWindows: liveWindows,
            claimedWindowIDs: unavailableWindowIDs
        )
        return bindingPlan.resolvedBindings.first
    }

    nonisolated private static func orderedLifecycleStartupCandidates(
        from candidates: [AppStreamWindowCandidate],
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>
    ) -> [AppStreamWindowCandidate] {
        candidates
            .enumerated()
            .filter { _, candidate in
                guard !excludedWindowIDs.contains(candidate.window.id) else { return false }
                guard candidate.parentWindowID == nil else { return false }
                guard !visibleWindowIDs.contains(candidate.window.id) else { return false }
                guard !claimedWindowIDs.contains(candidate.window.id) else { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lhsPriority = lifecycleStartupCandidatePriority(
                    windowID: lhs.element.window.id,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs
                )
                let rhsPriority = lifecycleStartupCandidatePriority(
                    windowID: rhs.element.window.id,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs
                )
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    nonisolated private static func lifecycleStartupCandidatePriority(
        windowID: WindowID,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>
    ) -> Int {
        let isPreferred = preferredWindowID == windowID
        let isDeprioritized = deprioritizedWindowIDs.contains(windowID)

        switch (isPreferred, isDeprioritized) {
        case (true, false):
            return 0
        case (false, false):
            return 1
        case (true, true):
            return 2
        case (false, true):
            return 3
        }
    }

    nonisolated private static func liveWindowsSnapshot(from content: SCShareableContent) -> [MirageWindow] {
        content.windows.compactMap { window -> MirageWindow? in
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
    }

    private func rejectMalformedAppListRequest(
        from clientContext: ClientContext,
        reason: String
    ) {
        MirageLogger.host("Rejecting malformed app list request from \(clientContext.client.name): \(reason)")
        let payload = ErrorMessage(
            code: .invalidMessage,
            message: "Invalid app list request payload"
        )
        if let response = try? ControlMessage(type: .error, content: payload) {
            clientContext.sendBestEffort(response)
        }
    }

    nonisolated static func isMalformedAppListRequestError(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }

        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }

        switch nsError.code {
        case CocoaError.Code.coderReadCorrupt.rawValue,
             CocoaError.Code.coderValueNotFound.rawValue:
            return true
        default:
            return false
        }
    }

    nonisolated static func malformedAppListRequestReason(from error: Error) -> String {
        if let decodeError = error as? DecodingError {
            return String(describing: decodeError)
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.localizedDescription
        }

        return String(describing: error)
    }

    func handleAppListRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        do {
            let request = try message.decode(AppListRequestMessage.self)
            MirageLogger.host(
                "Client \(clientContext.client.name) requested app list (requestID: \(request.requestID.uuidString), forceRefresh: \(request.forceRefresh), forceIconReset: \(request.forceIconReset), priorityCount: \(request.priorityBundleIdentifiers.count))"
            )

            updatePendingAppListRequest(
                clientID: clientContext.client.id,
                requestID: request.requestID,
                requestedForceRefresh: request.forceRefresh,
                forceIconReset: request.forceIconReset,
                priorityBundleIdentifiers: request.priorityBundleIdentifiers
            )

            await syncAppListRequestDeferralForInteractiveWorkload()
            sendPendingAppListRequestIfPossible()
        } catch {
            if Self.isMalformedAppListRequestError(error) {
                rejectMalformedAppListRequest(
                    from: clientContext,
                    reason: Self.malformedAppListRequestReason(from: error)
                )
                return
            }

            MirageLogger.error(.host, error: error, message: "Failed to handle app list request: ")
        }
    }

    func handleSelectApp(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(SelectAppMessage.self)
            let client = clientContext.client
            streamSetupCancelled = false
            guard !disconnectingClientIDs.contains(client.id),
                  clientsByID[client.id] != nil else {
                MirageLogger.host("Ignoring selectApp from disconnected client \(client.name)")
                return
            }
            MirageLogger.host("Client \(client.name) selected app: \(request.bundleIdentifier)")
            await pruneOrphanedAppSessions()

            let targetFrameRate = resolvedTargetFrameRate(request.targetFrameRate)
            MirageLogger.host("Frame rate: \(targetFrameRate)fps")

            let latencyMode = request.latencyMode ?? .lowestLatency
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
                    clientContext.sendBestEffort(response)
                }
                return
            }
            let requestedDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
            let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                pathKind: pathKind
            )
            let maxVisibleSlots = resolvedMaxVisibleAppWindowSlots(request.maxConcurrentVisibleWindows)
            let sharedBitrateBudget = resolvedAppSessionBitrateBudget(requestedBitrate: request.bitrate)
            let bitrateAllocationPolicy = request.bitrateAllocationPolicy ?? .prioritizeActiveWindow
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Performance mode: \(performanceMode.displayName)")
            MirageLogger
                .host(
                    "App stream slot cap: \(maxVisibleSlots), shared bitrate budget: \(sharedBitrateBudget.map { "\($0) bps" } ?? "none"), allocationPolicy: \(bitrateAllocationPolicy.rawValue)"
                )

            // Find the app in installed apps to get its path and name
            let apps = await appStreamManager.getInstalledApps(includeIcons: false)
            guard let app = apps
                .first(where: { $0.bundleIdentifier.lowercased() == request.bundleIdentifier.lowercased() }) else {
                MirageLogger.host("App \(request.bundleIdentifier) not found")
                sendAppSelectionError(to: clientContext, code: .windowNotFound, message: "App not found: \(request.bundleIdentifier)")
                return
            }

            if let existingSession = await appStreamManager.getSession(bundleIdentifier: app.bundleIdentifier),
               !existingSession.reservationExpired {
                let hasVisibleSlotCapacity = await appStreamManager.hasVisibleSlotCapacity(
                    bundleIdentifier: app.bundleIdentifier
                )
                let existingSessionDecision = Self.existingSessionSelectDecision(
                    sessionClientID: existingSession.clientID,
                    requestClientID: client.id,
                    sessionState: existingSession.state,
                    hasVisibleSlotCapacity: hasVisibleSlotCapacity
                )
                switch existingSessionDecision {
                case .allowExpansion:
                    break
                case .rejectOtherClientOwner:
                    sendAppSelectionError(
                        to: clientContext,
                        code: .windowNotFound,
                        message: "\(app.name) is already being streamed to another client"
                    )
                    return
                case .rejectSessionNotStreaming:
                    sendAppSelectionError(
                        to: clientContext,
                        code: .windowNotFound,
                        message: "\(app.name) is still starting; try again in a moment."
                    )
                    return
                case .rejectVisibleSlotCapReached:
                    sendAppSelectionError(
                        to: clientContext,
                        code: .windowNotFound,
                        message: "Max app windows reached for \(app.name)"
                    )
                    return
                }
                guard !disconnectingClientIDs.contains(existingSession.clientID),
                      let existingClientContext = findClientContext(clientID: existingSession.clientID) else {
                    sendAppSelectionError(
                        to: clientContext,
                        code: .windowNotFound,
                        message: "Client context unavailable for \(app.name)"
                    )
                    return
                }

                let expansionResult = await startAdditionalStreamForExistingAppSession(
                    app: app,
                    session: existingSession,
                    clientContext: existingClientContext,
                    selectRequest: request,
                    targetFrameRate: targetFrameRate,
                    requestedDisplayResolution: requestedDisplayResolution,
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize
                )
                switch expansionResult {
                case let .success(added):
                    try? await existingClientContext.send(.windowAddedToStream, content: added)
                    await sendAppWindowInventoryUpdate(bundleIdentifier: app.bundleIdentifier, clientID: client.id)
                    await startAppStreamGovernorsIfNeeded()
                    await markAppStreamInteraction(streamID: added.streamID, reason: "select app expansion")
                    await recomputeAppSessionBitrateBudget(
                        bundleIdentifier: app.bundleIdentifier,
                        reason: "selectApp existing session expansion"
                    )
                    MirageLogger.host(
                        "Expanded existing app stream \(app.bundleIdentifier) with window \(added.windowID) stream \(added.streamID)"
                    )
                    return
                case let .failure(reason):
                    sendAppSelectionError(
                        to: clientContext,
                        code: .windowNotFound,
                        message: reason
                    )
                    return
                }
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
                    to: clientContext,
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
                    to: clientContext,
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
                mediaMaxPacketSize: acceptedMediaMaxPacketSize
            )
            if streamSetupCancelled {
                MirageLogger.host("App stream setup cancelled by client; ending session for \(app.name)")
                for window in startupResult.windows {
                    if let session = activeStreams.first(where: { $0.id == window.streamID }) {
                        await stopStream(session, updateAppSession: false)
                    }
                }
                await appStreamManager.endSession(bundleIdentifier: app.bundleIdentifier)
                await restoreStageManagerAfterAppStreamingIfNeeded()
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
                return
            }

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
                    to: clientContext,
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
            clientContext.sendBestEffort(responseMessage)
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

    func handleAppWindowSwapRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let request = try message.decode(AppWindowSwapRequestMessage.self)
            let result = await performAppWindowSwap(
                bundleIdentifier: request.bundleIdentifier,
                targetSlotStreamID: request.targetSlotStreamID,
                targetWindowID: request.targetWindowID,
                clientID: clientContext.client.id
            )
            if let response = try? ControlMessage(type: .appWindowSwapResult, content: result) {
                clientContext.sendBestEffort(response)
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
                clientContext.sendBestEffort(response)
            }
        }
    }

    func performAppWindowSwap(
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

        let virtualDisplayState = getVirtualDisplayState(streamID: targetSlotStreamID)
        if let virtualDisplayState {
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
                    displayVisibleBounds: virtualDisplayState.displayVisibleBounds,
                    targetContentAspectRatio: virtualDisplayState.targetContentAspectRatio,
                    captureSourceRect: virtualDisplayState.captureSourceRect,
                    visiblePixelResolution: virtualDisplayState.visiblePixelResolution,
                    displayVisiblePixelResolution: virtualDisplayState.displayVisiblePixelResolution,
                    scaleFactor: virtualDisplayState.scaleFactor,
                    pixelResolution: virtualDisplayState.pixelResolution,
                    clientScaleFactor: virtualDisplayState.clientScaleFactor
                )
            )
            await context.updateWindowBinding(windowID: targetWindowID, ownerGeneration: newGeneration)
            activateWindow(targetWindow)
            _ = await enforceVirtualDisplayPlacementAfterActivation(windowID: targetWindowID, force: true)
            do {
                try await refreshSharedDisplayAppCaptureStateIfNeeded(
                    streamID: targetSlotStreamID,
                    reason: "slot swap"
                )
            } catch {
                return failure("Failed to retarget shared-display app capture state: \(error.localizedDescription)")
            }
        } else {
            return failure("Missing shared-display state for slot swap; direct window capture is disabled.")
        }

        let targetFrame = currentWindowFrame(for: targetWindowID) ?? CGRect(
            x: streamSession.window.frame.origin.x,
            y: streamSession.window.frame.origin.y,
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
        activateWindow(targetWindow)

        let processID = targetWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(windowID: targetWindowID, processID: processID)
        await appStreamManager.replaceVisibleWindowForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: targetSlotStreamID,
            newWindowID: targetWindowID,
            title: targetWindow.title,
            width: Int(targetWindow.frame.width),
            height: Int(targetWindow.frame.height),
            isResizable: isResizable,
            capturedClusterWindowIDs: await context.getCapturedClusterWindowIDs()
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
            let acceptedMediaMaxPacketSize = await context.getMediaMaxPacketSize()
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
                dimensionToken: dimensionToken,
                acceptedMediaMaxPacketSize: acceptedMediaMaxPacketSize
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

    private func startAdditionalStreamForExistingAppSession(
        app: MirageInstalledApp,
        session: MirageAppStreamSession,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        mediaMaxPacketSize: Int
    ) async -> ExistingSessionWindowStartResult {
        let normalizedBundleID = app.bundleIdentifier.lowercased()
        let catalog: [AppStreamWindowCandidate]
        do {
            catalog = try await AppStreamWindowCatalog.catalog(for: [app.bundleIdentifier])[normalizedBundleID] ?? []
        } catch {
            return .failure("Failed to enumerate windows for \(app.name): \(error.localizedDescription)")
        }

        let visibleWindowIDs = Set(session.windowStreams.keys)
        let activeOwnerClaimedWindowIDs = await WindowSpaceManager.shared.claimedWindowIDsForActiveOwners(
            activeStreamIDs: Set(activeSessionByStreamID.keys)
        )
        let claimedWindowIDs = visibleWindowIDs.union(activeOwnerClaimedWindowIDs)
        let candidateSelection = AppStreamWindowCatalog.startupCandidateSelection(from: catalog)
        if candidateSelection.usedFallback {
            MirageLogger.host(
                "Best-effort app stream candidate fallback engaged for \(app.bundleIdentifier); no strict primary windows were available"
            )
        }
        guard let selectedCandidate = candidateSelection.candidates.first(where: { !claimedWindowIDs.contains($0.window.id) }) else {
            return .failure("No additional \(app.name) windows are available to stream.")
        }

        let selectedWindow = selectedCandidate.window
        let existingStreamID = session.windowStreams.values.map(\.streamID).max()
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let encoderSettings = await existingContext?.getEncoderSettings()
        let streamScale = await existingContext?.getStreamScale() ?? (selectRequest.streamScale ?? 1.0)
        let inheritedTargetFrameRate = await existingContext?.getTargetFrameRate()
        let disableResolutionCap = await existingContext?.isResolutionCapDisabled() ?? (selectRequest.disableResolutionCap ?? false)
        let inheritedClientScaleFactor = existingStreamID.flatMap { clientVirtualDisplayScaleFactor(streamID: $0) }
        let preferredClientScaleFactor = session.requestedClientScaleFactor ??
            inheritedClientScaleFactor ??
            selectRequest.scaleFactor
        let audioConfiguration = audioConfigurationByClientID[session.clientID] ??
            selectRequest.audioConfiguration ??
            .default
        let requestedBitrate: Int? = if let sharedBudgetBps = session.bitrateBudgetBps {
            max(1_000_000, sharedBudgetBps / max(1, session.windowStreams.count + 1))
        } else {
            encoderSettings?.bitrate ?? selectRequest.bitrate
        }
        let preferredSlotIndex = await appStreamManager.availableVisibleSlotIndex(bundleIdentifier: app.bundleIdentifier)

        do {
            await prepareWindowForStreamingIfNeeded(
                selectedWindow,
                reason: "existing-session expansion"
            )
            let streamSession = try await startStream(
                for: selectedWindow,
                to: clientContext.client,
                expectedSessionID: clientContext.sessionID,
                clientDisplayResolution: requestedDisplayResolution,
                clientScaleFactor: preferredClientScaleFactor,
                keyFrameInterval: encoderSettings?.keyFrameInterval ?? selectRequest.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: inheritedTargetFrameRate ?? targetFrameRate,
                colorDepth: encoderSettings?.colorDepth ?? selectRequest.colorDepth,
                captureQueueDepth: encoderSettings?.captureQueueDepth ?? selectRequest.captureQueueDepth,
                bitrate: requestedBitrate,
                latencyMode: encoderSettings?.latencyMode ?? selectRequest.latencyMode ?? .lowestLatency,
                performanceMode: encoderSettings?.performanceMode ?? selectRequest.performanceMode ?? .standard,
                allowRuntimeQualityAdjustment: encoderSettings?.runtimeQualityAdjustmentEnabled ??
                    selectRequest.allowRuntimeQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: encoderSettings?
                    .lowLatencyHighResolutionCompressionBoostEnabled ??
                    selectRequest.lowLatencyHighResolutionCompressionBoost ??
                    true,
                disableResolutionCap: disableResolutionCap,
                allowBestEffortRemap: true,
                audioConfiguration: audioConfiguration,
                bitrateAdaptationCeiling: selectRequest.bitrateAdaptationCeiling,
                encoderMaxWidth: selectRequest.encoderMaxWidth,
                encoderMaxHeight: selectRequest.encoderMaxHeight,
                mediaMaxPacketSize: mediaMaxPacketSize,
                upscalingMode: selectRequest.upscalingMode,
                codec: selectRequest.codec,
                sizePreset: selectRequest.sizePreset ?? .standard
            )
            let resolvedWindowEvent = Self.resolvedWindowAddedEvent(from: streamSession)
            let resolvedWindowID = resolvedWindowEvent.windowID

            guard let confirmedSession = await appStreamManager.getSession(bundleIdentifier: app.bundleIdentifier),
                  case .streaming = confirmedSession.state,
                  confirmedSession.clientID == session.clientID else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return .failure("App session is no longer active for \(app.name).")
            }

            let processID = streamSession.window.application?.id ?? selectedWindow.application?.id ?? 0
            let isResizable = appStreamManager.checkWindowResizability(
                windowID: resolvedWindowID,
                processID: processID
            )
            let assignedSlot = await appStreamManager.addWindowToSession(
                bundleIdentifier: app.bundleIdentifier,
                windowID: resolvedWindowID,
                streamID: streamSession.id,
                title: resolvedWindowEvent.title,
                width: resolvedWindowEvent.width,
                height: resolvedWindowEvent.height,
                isResizable: isResizable,
                slotIndex: preferredSlotIndex
            )
            guard assignedSlot != nil else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return .failure("No visible slot is available for another \(app.name) window.")
            }
            if let context = streamsByID[streamSession.id] {
                await appStreamManager.setCapturedClusterWindowIDs(
                    bundleIdentifier: app.bundleIdentifier,
                    streamID: streamSession.id,
                    capturedClusterWindowIDs: await context.getCapturedClusterWindowIDs()
                )
            }
            await appStreamManager.noteWindowStartupSucceeded(
                bundleID: app.bundleIdentifier,
                windowID: selectedWindow.id
            )
            await appStreamManager.noteWindowStartupSucceeded(
                bundleID: app.bundleIdentifier,
                windowID: resolvedWindowID
            )

            return .success(
                WindowAddedToStreamMessage(
                    bundleIdentifier: app.bundleIdentifier,
                    streamID: streamSession.id,
                    windowID: resolvedWindowID,
                    title: resolvedWindowEvent.title,
                    width: resolvedWindowEvent.width,
                    height: resolvedWindowEvent.height,
                    isResizable: isResizable
                )
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? String(describing: error) : detail
            await appStreamManager.noteWindowStartupFailed(
                bundleID: app.bundleIdentifier,
                windowID: selectedWindow.id,
                retryable: false,
                reason: reason
            )
            return .failure("Failed to start additional \(app.name) window: \(reason)")
        }
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

    private func resolveCurrentInitialAppWindowBinding(
        bundleIdentifier: String,
        preferredWindowID: WindowID?,
        deprioritizedWindowIDs: Set<WindowID>,
        excludedWindowIDs: Set<WindowID>
    ) async throws -> ResolvedAppWindowBinding? {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return nil }

        let normalizedBundleID = bundleIdentifier.lowercased()
        let catalog = try await AppStreamWindowCatalog.catalog(for: [bundleIdentifier])
        let allCandidates = (catalog[normalizedBundleID] ?? [])
            .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
        let candidates = AppStreamWindowCatalog.startupCandidateSelection(from: allCandidates).candidates

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let liveWindows = Self.liveWindowsSnapshot(from: content)

        let activeOwnerClaimedWindowIDs = await WindowSpaceManager.shared.claimedWindowIDsForActiveOwners(
            activeStreamIDs: Set(activeSessionByStreamID.keys)
        )
        let claimedWindowIDs = Set(activeStreamIDByWindowID.keys).union(activeOwnerClaimedWindowIDs)
        let visibleWindowIDs = Set(session.windowStreams.keys)

        return Self.resolveInitialAppWindowStartupBinding(
            candidates: candidates,
            liveWindows: liveWindows,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs,
            preferredWindowID: preferredWindowID,
            deprioritizedWindowIDs: deprioritizedWindowIDs,
            excludedWindowIDs: excludedWindowIDs
        )
    }

    private func startInitialAppWindowStreams(
        app: MirageInstalledApp,
        client: MirageConnectedClient,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        mediaMaxPacketSize: Int
    ) async -> InitialAppWindowStartupResult {
        let maxDiscoveryAttempts = 14
        let maxConcurrentWindowStarts = 2
        let normalizedBundleID = app.bundleIdentifier.lowercased()
        var startedWindows: [AppStreamStartedMessage.AppStreamWindow] = []
        var failureNotes: [String] = []
        guard let clientContext = findClientContext(clientID: client.id) else {
            return InitialAppWindowStartupResult(
                windows: [],
                failureSummary: "client session is disconnected or superseded"
            )
        }
        var startupCandidates: [AppStreamWindowCandidate] = []
        var usedBestEffortStartupFallback = false
        var newWindowRequestAttempts = 0

        for discoveryAttempt in 1 ... maxDiscoveryAttempts {
            if streamSetupCancelled {
                MirageLogger.host("App stream window discovery cancelled by client")
                break
            }
            do {
                let catalog = try await AppStreamWindowCatalog.catalog(for: [app.bundleIdentifier])
                let allCandidates = (catalog[normalizedBundleID] ?? [])
                    .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
                let auxiliaryCount = allCandidates.filter { $0.classification == .auxiliary }.count
                if auxiliaryCount > 0 {
                    MirageLogger.host(
                        "Initial startup detected \(auxiliaryCount) auxiliary parent-coupled windows for \(app.bundleIdentifier)"
                    )
                }
                let selection = AppStreamWindowCatalog.startupCandidateSelection(from: allCandidates)
                startupCandidates = selection.candidates
                usedBestEffortStartupFallback = selection.usedFallback
                if !startupCandidates.isEmpty { break }
                if Self.shouldRequestNewAppWindowOnInitialDiscovery(
                    discoveryAttempt: discoveryAttempt,
                    newWindowRequestAttempts: newWindowRequestAttempts
                ) {
                    newWindowRequestAttempts += 1
                    await appStreamManager.requestNewWindow(
                        bundleIdentifier: app.bundleIdentifier,
                        path: app.path
                    )
                    MirageLogger.host(
                        "Initial app-stream startup requested a new window for \(app.bundleIdentifier) after discovery attempt \(discoveryAttempt) " +
                            "(request \(newWindowRequestAttempts))"
                    )
                }
                failureNotes.append("discovery \(discoveryAttempt): no startup-eligible app windows found")
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append("discovery \(discoveryAttempt): \(renderedDetail)")
                MirageLogger.error(.host, error: error, message: "Failed app-stream window discovery: ")
            }

            if discoveryAttempt < maxDiscoveryAttempts {
                try? await Task.sleep(for: Self.initialAppWindowDiscoveryRetryDelay(afterAttempt: discoveryAttempt))
            }
        }

        if startupCandidates.isEmpty {
            let summary = failureNotes.suffix(3).joined(separator: "; ")
            return InitialAppWindowStartupResult(
                windows: [],
                failureSummary: summary.isEmpty ? "no startup-eligible app windows became available" : summary
            )
        }

        if usedBestEffortStartupFallback {
            MirageLogger.host(
                "Initial app-stream startup using a best-effort fallback candidate for \(app.bundleIdentifier) because no strict primary window became available"
            )
        }

        let bindingPlan: AppWindowBindingPlan
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let liveWindows = Self.liveWindowsSnapshot(from: content)
            let activeOwnerClaimedWindowIDs = await WindowSpaceManager.shared.claimedWindowIDsForActiveOwners(
                activeStreamIDs: Set(activeSessionByStreamID.keys)
            )
            let claimedWindowIDs = Set(activeStreamIDByWindowID.keys).union(activeOwnerClaimedWindowIDs)
            bindingPlan = AppWindowBindingPlanner.plan(
                candidates: startupCandidates,
                liveWindows: liveWindows,
                claimedWindowIDs: claimedWindowIDs
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedDetail = detail.isEmpty ? String(describing: error) : detail
            failureNotes.append("binding plan snapshot failed: \(renderedDetail)")
            bindingPlan = AppWindowBindingPlan(
                resolvedBindings: [],
                unresolvedCandidates: startupCandidates
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
                await emitWindowStreamFailed(
                    to: clientContext,
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: candidate.window.id,
                    title: initialStreamFailureTitle(for: candidate, appName: app.name),
                    reason: reason
                )
                MirageLogger.host(
                    "Initial app-stream startup failed permanently for \(candidate.window.id): \(reason) (\(candidate.logMetadata))"
                )
            case .suppressed:
                break
            }
        }

        let visibleBindings: [(slotIndex: Int, binding: ResolvedAppWindowBinding)] = Array(
            bindingPlan.resolvedBindings
                .prefix(1)
                .enumerated()
                .map { index, binding in
                    (slotIndex: index, binding: binding)
                }
        )
        let overflowBindings = Array(bindingPlan.resolvedBindings.dropFirst(1))
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
                        clientContext: clientContext,
                        selectRequest: selectRequest,
                        targetFrameRate: targetFrameRate,
                        requestedDisplayResolution: requestedDisplayResolution,
                        startupBitratePerVisibleWindow: startupBitratePerVisibleWindow,
                        mediaMaxPacketSize: mediaMaxPacketSize
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
            failureSummary: summary.isEmpty ? "no startup-eligible app windows became available" : summary
        )
    }

    private func startInitialAppWindowBinding(
        app: MirageInstalledApp,
        binding: ResolvedAppWindowBinding,
        preferredSlotIndex: Int,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        startupBitratePerVisibleWindow: Int?,
        mediaMaxPacketSize: Int
    ) async -> InitialAppWindowStartAttemptResult {
        var failureNotes: [String] = []
        let startupDeadline = ContinuousClock.now + appWindowReplacementCooldownDuration
        var slotAttempt = 0
        var preferredWindowID: WindowID? = binding.resolvedWindow.id
        var deprioritizedWindowIDs: Set<WindowID> = []
        var excludedWindowIDs: Set<WindowID> = []
        var currentBinding = binding

        while ContinuousClock.now < startupDeadline {
            slotAttempt += 1

            do {
                guard let resolvedBinding = try await resolveCurrentInitialAppWindowBinding(
                    bundleIdentifier: app.bundleIdentifier,
                    preferredWindowID: preferredWindowID,
                    deprioritizedWindowIDs: deprioritizedWindowIDs,
                    excludedWindowIDs: excludedWindowIDs
                ) else {
                    failureNotes.append(
                        "slot \(preferredSlotIndex) attempt \(slotAttempt): no startup-eligible app windows available"
                    )
                    if ContinuousClock.now < startupDeadline {
                        try? await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                    }
                    continue
                }
                currentBinding = resolvedBinding
                preferredWindowID = currentBinding.resolvedWindow.id
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                failureNotes.append(
                    "slot \(preferredSlotIndex) attempt \(slotAttempt): binding refresh failed: \(renderedDetail)"
                )
                MirageLogger.error(.host, error: error, message: "Failed to refresh initial app-stream binding: ")
                if ContinuousClock.now < startupDeadline {
                    try? await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                }
                continue
            }

            do {
                await prepareWindowForStreamingIfNeeded(
                    currentBinding.resolvedWindow,
                    reason: "initial app-stream startup"
                )
                if let reboundBinding = try await resolveCurrentInitialAppWindowBinding(
                    bundleIdentifier: app.bundleIdentifier,
                    preferredWindowID: currentBinding.resolvedWindow.id,
                    deprioritizedWindowIDs: deprioritizedWindowIDs,
                    excludedWindowIDs: excludedWindowIDs
                ) {
                    if reboundBinding.candidate.window.id != currentBinding.candidate.window.id ||
                        reboundBinding.resolvedWindow.id != currentBinding.resolvedWindow.id {
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) rebound startup target " +
                                "candidate \(currentBinding.candidate.window.id)->\(reboundBinding.candidate.window.id) " +
                                "resolved \(currentBinding.resolvedWindow.id)->\(reboundBinding.resolvedWindow.id) after preparation"
                        )
                    }
                    currentBinding = reboundBinding
                    preferredWindowID = reboundBinding.resolvedWindow.id
                }

                let startedWindow = try await attemptStartInitialAppWindowStream(
                    app: app,
                    startupCandidate: currentBinding.candidate,
                    preferredWindow: currentBinding.resolvedWindow,
                    preferredSlotIndex: preferredSlotIndex,
                    clientContext: clientContext,
                    selectRequest: selectRequest,
                    targetFrameRate: targetFrameRate,
                    requestedDisplayResolution: requestedDisplayResolution,
                    requestedBitrateOverride: startupBitratePerVisibleWindow,
                    mediaMaxPacketSize: mediaMaxPacketSize
                )
                let succeededWindowIDs = Set([
                    binding.candidate.window.id,
                    currentBinding.candidate.window.id,
                    currentBinding.resolvedWindow.id,
                    startedWindow.windowID,
                ])
                for windowID in succeededWindowIDs {
                    await appStreamManager.noteWindowStartupSucceeded(
                        bundleID: app.bundleIdentifier,
                        windowID: windowID
                    )
                }
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
                let failedWindowIDs = Set([
                    currentBinding.candidate.window.id,
                    currentBinding.resolvedWindow.id,
                ])
                let failedWindowList = failedWindowIDs
                    .sorted(by: <)
                    .map(String.init)
                    .joined(separator: ",")
                failureNotes.append(
                    "slot \(preferredSlotIndex) attempt \(slotAttempt) window(s) \(failedWindowList): \(renderedDetail)"
                )

                let retryable = AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error)
                let shouldMoveToHiddenInventory = AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error)

                for failedWindowID in failedWindowIDs {
                    let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                        bundleID: app.bundleIdentifier,
                        windowID: failedWindowID,
                        retryable: retryable,
                        reason: renderedDetail
                    )
                    if case let .retryScheduled(retryAttempt, retryAt) = failureDisposition {
                        MirageLogger.host(
                            "Initial app-stream slot \(preferredSlotIndex) retry scheduled for window \(failedWindowID) " +
                                "attempt \(retryAttempt) at \(retryAt)"
                        )
                    }
                }

                if shouldMoveToHiddenInventory {
                    let resolved = currentBinding.resolvedWindow
                    let processID = resolved.application?.id ??
                        currentBinding.candidate.window.application?.id ??
                        0
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
                    for windowID in failedWindowIDs {
                        await appStreamManager.noteWindowStartupSucceeded(
                            bundleID: app.bundleIdentifier,
                            windowID: windowID
                        )
                    }
                    excludedWindowIDs.formUnion(failedWindowIDs)
                    deprioritizedWindowIDs.subtract(failedWindowIDs)
                    MirageLogger.host(
                        "Initial app-stream slot \(preferredSlotIndex) moved window \(resolved.id) to hidden inventory " +
                            "after lifecycle startup failure: \(renderedDetail) (\(currentBinding.candidate.logMetadata))"
                    )
                } else {
                    if retryable {
                        deprioritizedWindowIDs.formUnion(failedWindowIDs)
                    } else {
                        excludedWindowIDs.formUnion(failedWindowIDs)
                    }
                    MirageLogger.host(
                        "Initial app-stream slot \(preferredSlotIndex) lifecycle retry continuing after startup failure: " +
                            "\(renderedDetail) (\(currentBinding.candidate.logMetadata))"
                    )
                }

                if ContinuousClock.now < startupDeadline {
                    try? await Task.sleep(for: Self.initialAppWindowSlotRetryDelay(afterAttempt: slotAttempt))
                }
            }
        }

        return InitialAppWindowStartAttemptResult(startedWindow: nil, failureNotes: failureNotes)
    }

    private func attemptStartInitialAppWindowStream(
        app: MirageInstalledApp,
        startupCandidate: AppStreamWindowCandidate,
        preferredWindow: MirageWindow,
        preferredSlotIndex: Int,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedDisplayResolution: CGSize,
        requestedBitrateOverride: Int?,
        mediaMaxPacketSize: Int
    ) async throws -> AppStreamStartedMessage.AppStreamWindow {
        let streamSession = try await startStream(
            for: preferredWindow,
            to: clientContext.client,
            expectedSessionID: clientContext.sessionID,
            clientDisplayResolution: requestedDisplayResolution,
            clientScaleFactor: selectRequest.scaleFactor,
            keyFrameInterval: selectRequest.keyFrameInterval,
            streamScale: selectRequest.streamScale ?? 1.0,
            targetFrameRate: targetFrameRate,
            colorDepth: selectRequest.colorDepth,
            captureQueueDepth: selectRequest.captureQueueDepth,
            bitrate: requestedBitrateOverride ?? selectRequest.bitrate,
            latencyMode: selectRequest.latencyMode ?? .lowestLatency,
            performanceMode: selectRequest.performanceMode ?? .standard,
            allowRuntimeQualityAdjustment: selectRequest.allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: selectRequest.lowLatencyHighResolutionCompressionBoost ?? true,
            disableResolutionCap: selectRequest.disableResolutionCap ?? false,
            allowBestEffortRemap: true,
            audioConfiguration: selectRequest.audioConfiguration ?? .default,
            bitrateAdaptationCeiling: selectRequest.bitrateAdaptationCeiling,
            encoderMaxWidth: selectRequest.encoderMaxWidth,
            encoderMaxHeight: selectRequest.encoderMaxHeight,
            mediaMaxPacketSize: mediaMaxPacketSize,
            upscalingMode: selectRequest.upscalingMode,
            codec: selectRequest.codec,
            sizePreset: selectRequest.sizePreset ?? .standard
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

        if let context = streamsByID[streamSession.id] {
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: app.bundleIdentifier,
                streamID: streamSession.id,
                capturedClusterWindowIDs: await context.getCapturedClusterWindowIDs()
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

    private func initialStreamFailureTitle(for candidate: AppStreamWindowCandidate, appName: String) -> String {
        if let title = candidate.window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "\(appName) window #\(candidate.window.id)"
    }

    private func sendAppSelectionError(
        to clientContext: ClientContext,
        code: ErrorMessage.ErrorCode,
        message: String
    ) {
        let error = ErrorMessage(code: code, message: message)
        guard let response = try? ControlMessage(type: .error, content: error) else { return }
        clientContext.sendBestEffort(response)
    }

    func isInteractiveWorkloadActiveForAppListRequests() -> Bool {
        Self.shouldDeferAppListRequestsForInteractiveWorkload(
            hasActiveAppStreams: !activeStreams.isEmpty,
            hasDesktopStream: desktopStreamContext != nil,
            hasPendingAppStreamStart: pendingAppStreamStartCount > 0,
            hasPendingDesktopStreamStart: pendingDesktopStreamStartCount > 0
        )
    }

    func syncAppListRequestDeferralForInteractiveWorkload() async {
        let shouldDefer = isInteractiveWorkloadActiveForAppListRequests()
        let transition = Self.appListRequestDeferralTransition(
            wasDeferred: appListRequestDeferredForInteractiveWorkload,
            shouldDefer: shouldDefer
        )

        switch transition {
        case .remainIdle:
            if appListRequestTask == nil {
                sendPendingAppListRequestIfPossible()
            }
            sendPendingNonEssentialMetadataRequestsIfPossible()
        case .beginDeferral:
            appListRequestDeferredForInteractiveWorkload = true
            if appListRequestTask != nil {
                MirageLogger.host("Cancelling app list request while interactive workload is active")
            }
            appListRequestTask?.cancel()
            appListRequestTask = nil
            await appStreamManager.cancelAppListScans()
        case .remainDeferred:
            if appListRequestTask != nil {
                appListRequestTask?.cancel()
                appListRequestTask = nil
            }
            await appStreamManager.cancelAppListScans()
        case .resumeDeferred:
            appListRequestDeferredForInteractiveWorkload = false
            MirageLogger.host("Interactive workload idle; resuming deferred app list request if needed")
            sendPendingAppListRequestIfPossible()
            sendPendingNonEssentialMetadataRequestsIfPossible()
        }
    }

    private func cancelPendingNonEssentialMetadataRequestTasks() {
        hostHardwareIconRequestTask?.cancel()
        hostHardwareIconRequestTask = nil
        hostWallpaperRequestTask?.cancel()
        hostWallpaperRequestTask = nil
        hostSoftwareUpdateStatusRequestTask?.cancel()
        hostSoftwareUpdateStatusRequestTask = nil
    }

    private func sendPendingNonEssentialMetadataRequestsIfPossible() {
        sendPendingHostHardwareIconRequestIfPossible()
        sendPendingHostWallpaperRequestIfPossible()
        sendPendingHostSoftwareUpdateStatusRequestIfPossible()
    }

    private func updatePendingAppListRequest(
        clientID: UUID,
        requestID: UUID,
        requestedForceRefresh: Bool,
        forceIconReset: Bool,
        priorityBundleIdentifiers: [String]
    ) {
        let normalizedPriorityBundleIdentifiers = Self.normalizedBundleIdentifierList(priorityBundleIdentifiers)
        if var pending = pendingAppListRequest, pending.clientID == clientID {
            pending.requestID = requestID
            pending.requestedForceRefresh = pending.requestedForceRefresh || requestedForceRefresh
            pending.forceIconReset = pending.forceIconReset || forceIconReset
            pending.priorityBundleIdentifiers = normalizedPriorityBundleIdentifiers
            pendingAppListRequest = pending
            return
        }
        pendingAppListRequest = PendingAppListRequest(
            clientID: clientID,
            requestID: requestID,
            requestedForceRefresh: requestedForceRefresh,
            forceIconReset: forceIconReset,
            priorityBundleIdentifiers: normalizedPriorityBundleIdentifiers
        )
    }

    private func sendPendingAppListRequestIfPossible() {
        guard !isInteractiveWorkloadActiveForAppListRequests() else {
            appListRequestDeferredForInteractiveWorkload = true
            return
        }
        appListRequestDeferredForInteractiveWorkload = false
        guard let pending = pendingAppListRequest else { return }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingAppListRequest = nil
            return
        }

        appListRequestTask?.cancel()
        if sessionState != .ready {
            MirageLogger.host("Session is \(sessionState); deferring app list request until ready")
            return
        }
        let forceRefresh = pending.requestedForceRefresh
        let forceIconReset = pending.forceIconReset
        let requestID = pending.requestID
        let priorityBundleIdentifiers = pending.priorityBundleIdentifiers
        let clientID = pending.clientID
        let token = UUID()
        appListRequestToken = token

        appListRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await pruneOrphanedAppSessions()

            let apps = await appStreamManager.getInstalledApps(
                includeIcons: false,
                forceRefresh: forceRefresh
            )
            if Task.isCancelled { return }

            do {
                let response = AppListMessage(
                    requestID: requestID,
                    apps: Self.metadataOnlyApps(apps)
                )
                try await clientContext.send(.appList, content: response)
                MirageLogger.host("Sent metadata app list with \(apps.count) apps to \(clientContext.client.name)")
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "App list response",
                    sessionID: clientContext.sessionID
                )
                return
            }

            await streamAppIconUpdates(
                apps: apps,
                requestID: requestID,
                clientID: clientID,
                clientContext: clientContext,
                forceIconReset: forceIconReset,
                priorityBundleIdentifiers: priorityBundleIdentifiers
            )

            if Task.isCancelled { return }
            if appListRequestToken == token, pendingAppListRequest?.clientID == clientID {
                pendingAppListRequest = nil
            }
        }
    }

    private func streamAppIconUpdates(
        apps: [MirageInstalledApp],
        requestID: UUID,
        clientID: UUID,
        clientContext: ClientContext,
        forceIconReset: Bool,
        priorityBundleIdentifiers: [String]
    ) async {
        var persistedSignatures = await appIconSignatureStore.signatures(for: clientID)
        var signatureUpdates: [String: String] = [:]
        var skippedBundleIdentifiers: [String] = []
        var sentIconCount = 0

        let orderedApps = Self.orderedAppsForIconStreaming(
            apps: apps,
            priorityBundleIdentifiers: priorityBundleIdentifiers
        )

        for app in orderedApps {
            if Task.isCancelled { return }

            guard let iconData = await appStreamManager.iconDataForInstalledApp(
                atPath: app.path,
                maxPixelSize: 128,
                heifCompressionQuality: 0.72
            ) else {
                continue
            }

            let normalizedBundleIdentifier = app.bundleIdentifier.lowercased()
            let iconSignature = Self.sha256Hex(iconData)

            if !forceIconReset,
               persistedSignatures[normalizedBundleIdentifier] == iconSignature {
                skippedBundleIdentifiers.append(app.bundleIdentifier)
                continue
            }

            let update = AppIconUpdateMessage(
                requestID: requestID,
                bundleIdentifier: app.bundleIdentifier,
                iconData: iconData,
                iconSignature: iconSignature
            )

            do {
                try await clientContext.send(.appIconUpdate, content: update)
                sentIconCount += 1
                signatureUpdates[normalizedBundleIdentifier] = iconSignature
                persistedSignatures[normalizedBundleIdentifier] = iconSignature
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "App icon update for \(app.bundleIdentifier)",
                    sessionID: clientContext.sessionID
                )
                return
            }
        }

        if signatureUpdates.isEmpty {
            await appIconSignatureStore.touch(clientID: clientID)
        } else {
            await appIconSignatureStore.mergeSignatures(signatureUpdates, for: clientID)
        }

        let completion = AppIconStreamCompleteMessage(
            requestID: requestID,
            sentIconCount: sentIconCount,
            skippedBundleIdentifiers: skippedBundleIdentifiers
        )

        do {
            try await clientContext.send(.appIconStreamComplete, content: completion)
            MirageLogger.host(
                "App icon stream complete for \(clientContext.client.name) requestID=\(requestID.uuidString) sent=\(sentIconCount) skipped=\(skippedBundleIdentifiers.count)"
            )
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "App icon stream completion",
                sessionID: clientContext.sessionID
            )
        }
    }

    private static func metadataOnlyApps(_ apps: [MirageInstalledApp]) -> [MirageInstalledApp] {
        apps.map { app in
            MirageInstalledApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                path: app.path,
                iconData: nil,
                version: app.version,
                isRunning: app.isRunning,
                isBeingStreamed: app.isBeingStreamed
            )
        }
    }

    private static func orderedAppsForIconStreaming(
        apps: [MirageInstalledApp],
        priorityBundleIdentifiers: [String]
    ) -> [MirageInstalledApp] {
        let normalizedPriority = normalizedBundleIdentifierList(priorityBundleIdentifiers)
        guard !normalizedPriority.isEmpty else { return apps }

        var appsByBundleIdentifier: [String: MirageInstalledApp] = [:]
        appsByBundleIdentifier.reserveCapacity(apps.count)
        for app in apps {
            appsByBundleIdentifier[app.bundleIdentifier.lowercased()] = app
        }

        var orderedApps: [MirageInstalledApp] = []
        orderedApps.reserveCapacity(apps.count)
        var consumedBundleIdentifiers: Set<String> = []

        for normalizedBundleIdentifier in normalizedPriority {
            guard let app = appsByBundleIdentifier[normalizedBundleIdentifier] else { continue }
            guard consumedBundleIdentifiers.insert(normalizedBundleIdentifier).inserted else { continue }
            orderedApps.append(app)
        }

        for app in apps {
            let normalizedBundleIdentifier = app.bundleIdentifier.lowercased()
            guard consumedBundleIdentifiers.insert(normalizedBundleIdentifier).inserted else { continue }
            orderedApps.append(app)
        }

        return orderedApps
    }

    private static func normalizedBundleIdentifierList(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(bundleIdentifiers.count)

        for bundleIdentifier in bundleIdentifiers {
            let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneOrphanedAppSessions() async {
        let connectedClientIDs = Set(connectedClients.map(\.id))
        await appStreamManager.endSessionsNotOwned(by: connectedClientIDs)
    }
}

#endif
