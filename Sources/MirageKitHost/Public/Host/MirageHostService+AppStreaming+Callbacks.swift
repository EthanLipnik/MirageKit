//
//  MirageHostService+AppStreaming+Callbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream callbacks.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    struct ResolvedWindowAddedEvent: Sendable, Equatable {
        let windowID: WindowID
        let title: String?
        let width: Int
        let height: Int
    }

    nonisolated static func resolvedWindowAddedEvent(
        from streamSession: MirageStreamSession
    ) -> ResolvedWindowAddedEvent {
        let resolvedWindow = streamSession.window
        return ResolvedWindowAddedEvent(
            windowID: resolvedWindow.id,
            title: resolvedWindow.title,
            width: Int(resolvedWindow.frame.width),
            height: Int(resolvedWindow.frame.height)
        )
    }

    func findClientContext(clientID: UUID) -> ClientContext? {
        clientsByConnection.values.first { $0.client.id == clientID }
    }

    func setupAppStreamManagerCallbacks() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            await appStreamManager.setOnNewWindowDetected { [weak self] bundleID, candidate in
                Task { @MainActor in
                    await self?.handleNewWindowFromStreamedApp(bundleID: bundleID, candidate: candidate)
                }
            }

            await appStreamManager.setOnWindowClosed { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleWindowClosedFromStreamedApp(bundleID: bundleID, windowID: windowID)
                }
            }

            await appStreamManager.setOnAppTerminated { [weak self] bundleID in
                Task { @MainActor in
                    await self?.handleStreamedAppTerminated(bundleID: bundleID)
                }
            }
        }
    }

    func handleNewWindowFromStreamedApp(bundleID: String, candidate: AppStreamWindowCandidate) async {
        let windowID = candidate.window.id
        if candidate.classification == .auxiliary {
            MirageLogger.host(
                "Skipping auxiliary child window for independent stream startup: \(windowID) (\(candidate.logMetadata))"
            )
            return
        }

        guard let initialSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
              case .streaming = initialSession.state else {
            return
        }

        // Ignore duplicate add signals for windows already tracked in-session.
        if await appStreamManager.hasTrackedWindow(bundleIdentifier: bundleID, windowID: windowID) { return }

        let existingStreamID = initialSession.windowStreams.values.map(\.streamID).max()
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let streamScale = await existingContext?.getStreamScale() ?? 1.0
        let encoderSettings = await existingContext?.getEncoderSettings()
        let targetFrameRate = await existingContext?.getTargetFrameRate()
        let audioConfiguration = audioConfigurationByClientID[initialSession.clientID] ?? .default
        let disableResolutionCap = await existingContext?.isResolutionCapDisabled() ?? false
        let inheritedClientScaleFactor = existingStreamID.flatMap { clientVirtualDisplayScaleFactor(streamID: $0) }
        let mirageWindow = candidate.window

        guard let liveSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
              case .streaming = liveSession.state,
              liveSession.clientID == initialSession.clientID,
              !disconnectingClientIDs.contains(liveSession.clientID),
              let clientContext = findClientContext(clientID: liveSession.clientID) else {
            return
        }

        let preferredDisplayResolution: CGSize = {
            if liveSession.requestedDisplayResolution.width > 0, liveSession.requestedDisplayResolution.height > 0 {
                return liveSession.requestedDisplayResolution
            }
            if let inheritedBoundsSize = existingStreamID.flatMap({ getVirtualDisplayState(streamID: $0)?.bounds.size }),
               inheritedBoundsSize.width > 0,
               inheritedBoundsSize.height > 0 {
                return inheritedBoundsSize
            }
            return mirageWindow.frame.size
        }()
        let preferredClientScaleFactor = liveSession.requestedClientScaleFactor ?? inheritedClientScaleFactor
        let startupBitratePerVisibleWindow: Int? = if let sharedBudgetBps = liveSession.bitrateBudgetBps {
            max(1_000_000, sharedBudgetBps / max(1, liveSession.windowStreams.count + 1))
        } else {
            encoderSettings?.bitrate
        }

        let hasVisibleSlotCapacity = await appStreamManager.hasVisibleSlotCapacity(bundleIdentifier: bundleID)
        if !hasVisibleSlotCapacity {
            let processID = mirageWindow.application?.id ?? 0
            let isResizable = appStreamManager.checkWindowResizability(
                windowID: windowID,
                processID: processID
            )
            await appStreamManager.upsertHiddenWindow(
                bundleIdentifier: bundleID,
                windowID: windowID,
                title: mirageWindow.title,
                width: Int(mirageWindow.frame.width),
                height: Int(mirageWindow.frame.height),
                isResizable: isResizable
            )
            await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: liveSession.clientID)
            await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window hidden overflow")
            MirageLogger.host(
                "Tracked overflow window \(windowID) as hidden inventory for \(bundleID) (slot cap reached)"
            )
            return
        }

        do {
            let streamSession = try await startStream(
                for: mirageWindow,
                to: clientContext.client,
                dataPort: nil,
                clientDisplayResolution: preferredDisplayResolution,
                clientScaleFactor: preferredClientScaleFactor,
                keyFrameInterval: encoderSettings?.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate,
                bitDepth: encoderSettings?.bitDepth,
                captureQueueDepth: encoderSettings?.captureQueueDepth,
                bitrate: startupBitratePerVisibleWindow,
                latencyMode: encoderSettings?.latencyMode ?? .auto,
                performanceMode: encoderSettings?.performanceMode ?? .standard,
                lowLatencyHighResolutionCompressionBoost: encoderSettings?
                    .lowLatencyHighResolutionCompressionBoostEnabled ?? true,
                disableResolutionCap: disableResolutionCap,
                allowBestEffortRemap: false,
                audioConfiguration: audioConfiguration
            )
            let resolvedWindowEvent = Self.resolvedWindowAddedEvent(from: streamSession)
            let resolvedWindowID = resolvedWindowEvent.windowID

            guard let confirmedSession = await appStreamManager.getSession(bundleIdentifier: bundleID),
                  case .streaming = confirmedSession.state,
                  confirmedSession.clientID == liveSession.clientID else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return
            }

            let isResizable = appStreamManager.checkWindowResizability(
                windowID: resolvedWindowID,
                processID: streamSession.window.application?.id ?? mirageWindow.application?.id ?? 0
            )

            let assignedSlot = await appStreamManager.addWindowToSession(
                bundleIdentifier: bundleID,
                windowID: resolvedWindowEvent.windowID,
                streamID: streamSession.id,
                title: resolvedWindowEvent.title,
                width: resolvedWindowEvent.width,
                height: resolvedWindowEvent.height,
                isResizable: isResizable
            )
            guard assignedSlot != nil else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                MirageLogger.host(
                    "Rejected new window \(windowID) (resolved \(resolvedWindowID)) for app stream \(bundleID): window already bound"
                )
                return
            }
            await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)
            await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: resolvedWindowID)

            let response = WindowAddedToStreamMessage(
                bundleIdentifier: bundleID,
                streamID: streamSession.id,
                windowID: resolvedWindowEvent.windowID,
                title: resolvedWindowEvent.title,
                width: resolvedWindowEvent.width,
                height: resolvedWindowEvent.height,
                isResizable: isResizable
            )
            try? await clientContext.send(.windowAddedToStream, content: response)
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: liveSession.clientID)
            await startAppStreamGovernorsIfNeeded()
            await markAppStreamInteraction(streamID: streamSession.id, reason: "window added")
            await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window added")

            MirageLogger.host(
                "Added new window \(windowID) (resolved \(resolvedWindowID)) to app stream \(bundleID)"
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? String(describing: error) : detail

            let retryable = AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error)
            let failureDisposition = await appStreamManager.noteWindowStartupFailed(
                bundleID: bundleID,
                windowID: windowID,
                retryable: retryable,
                reason: reason
            )
            let shouldMoveToHiddenInventory = AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error)
            switch failureDisposition {
            case let .retryScheduled(attempt, retryAt):
                MirageLogger.host(
                    "App window startup retry scheduled for \(windowID) attempt \(attempt) at \(retryAt) (\(candidate.logMetadata))"
                )
            case .terminal:
                if shouldMoveToHiddenInventory {
                    let processID = mirageWindow.application?.id ?? 0
                    let isResizable = appStreamManager.checkWindowResizability(
                        windowID: windowID,
                        processID: processID
                    )
                    await appStreamManager.upsertHiddenWindow(
                        bundleIdentifier: bundleID,
                        windowID: windowID,
                        title: mirageWindow.title,
                        width: Int(mirageWindow.frame.width),
                        height: Int(mirageWindow.frame.height),
                        isResizable: isResizable
                    )
                    await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)
                    await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: liveSession.clientID)
                    await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window hidden after startup failure")
                    MirageLogger.host(
                        "App window startup moved \(windowID) to hidden inventory after non-retryable startup failure: \(reason) (\(candidate.logMetadata))"
                    )
                } else {
                    let fallbackTitle = streamFailureTitle(
                        for: mirageWindow,
                        appName: initialSession.appName
                    )
                    await emitWindowStreamFailed(
                        to: clientContext,
                        bundleIdentifier: bundleID,
                        windowID: windowID,
                        title: fallbackTitle,
                        reason: reason
                    )
                    MirageLogger.host(
                        "App window startup failed permanently for \(windowID): \(reason) (\(candidate.logMetadata))"
                    )
                }
            case .suppressed:
                break
            }
            MirageLogger.error(.host, error: error, message: "Failed to start stream for new window: ")
            await endAppSessionIfIdle(bundleIdentifier: bundleID)
        }
    }

    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        let windowInfo = session.windowStreams[windowID]
        let hiddenWindowInfo = session.hiddenWindows[windowID]

        if let streamID = windowInfo?.streamID,
           let streamSession = activeSessionByStreamID[streamID] {
            await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
        }

        let removedInfo = await appStreamManager.removeWindowFromSession(
            bundleIdentifier: bundleID,
            windowID: windowID
        )
        if removedInfo != nil {
            await emitWindowRemovedFromStream(
                to: clientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                reason: .noLongerEligible
            )
            await backfillVisibleSlotsFromHiddenWindows(bundleID: bundleID)
        }
        if hiddenWindowInfo != nil || removedInfo != nil {
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
            await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window closed")
        }

        await endAppSessionIfIdle(bundleIdentifier: bundleID)
        MirageLogger.host("Removed window \(windowID) from app stream \(bundleID)")
    }

    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        inputController.clearAllModifiers()

        let closedWindowIDs = session.windowStreams.keys.sorted(by: <)

        for windowID in closedWindowIDs {
            if let windowInfo = session.windowStreams[windowID],
               let streamSession = activeSessionByStreamID[windowInfo.streamID] {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            }

            await emitWindowRemovedFromStream(
                to: clientContext,
                bundleIdentifier: bundleID,
                windowID: windowID,
                reason: .appTerminated
            )
        }

        let allSessions = await appStreamManager.getAllSessions()
        let hasRemainingWindows = allSessions.contains { candidate in
            candidate.bundleIdentifier.lowercased() != bundleID.lowercased() &&
                candidate.clientID == session.clientID &&
                !candidate.windowStreams.isEmpty
        }

        let terminated = AppTerminatedMessage(
            bundleIdentifier: bundleID,
            closedWindowIDs: closedWindowIDs,
            hasRemainingWindows: hasRemainingWindows
        )
        try? await clientContext.send(.appTerminated, content: terminated)

        await appStreamManager.endSession(bundleIdentifier: bundleID)
        await restoreStageManagerAfterAppStreamingIfNeeded()

        MirageLogger.host("App \(bundleID) terminated, ended session")
    }

    func backfillVisibleSlotsFromHiddenWindows(bundleID: String) async {
        while await appStreamManager.hasVisibleSlotCapacity(bundleIdentifier: bundleID) {
            guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
                  case .streaming = session.state,
                  let clientContext = findClientContext(clientID: session.clientID) else {
                return
            }

            guard let hiddenWindowID = await appStreamManager.inventoryMessage(bundleIdentifier: bundleID)?
                .hiddenWindows
                .first?
                .windowID,
                let hiddenInfo = await appStreamManager.hiddenWindowInfo(
                    bundleIdentifier: bundleID,
                    windowID: hiddenWindowID
                ) else {
                return
            }

            let existingStreamID = session.windowStreams.values.map(\.streamID).max()
            let existingContext = existingStreamID.flatMap { streamsByID[$0] }
            let streamScale = await existingContext?.getStreamScale() ?? 1.0
            let encoderSettings = await existingContext?.getEncoderSettings()
            let targetFrameRate = await existingContext?.getTargetFrameRate()
            let disableResolutionCap = await existingContext?.isResolutionCapDisabled() ?? false
            let inheritedClientScaleFactor = existingStreamID.flatMap { clientVirtualDisplayScaleFactor(streamID: $0) }
            let preferredClientScaleFactor = session.requestedClientScaleFactor ?? inheritedClientScaleFactor
            let requestedResolution = if session.requestedDisplayResolution.width > 0, session.requestedDisplayResolution.height > 0 {
                session.requestedDisplayResolution
            } else {
                CGSize(width: max(1, hiddenInfo.width), height: max(1, hiddenInfo.height))
            }
            let audioConfiguration = audioConfigurationByClientID[session.clientID] ?? .default

            let placeholderWindow = MirageWindow(
                id: hiddenWindowID,
                title: hiddenInfo.title,
                application: MirageApplication(
                    id: 0,
                    bundleIdentifier: session.bundleIdentifier,
                    name: session.appName
                ),
                frame: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(max(1, hiddenInfo.width)),
                    height: CGFloat(max(1, hiddenInfo.height))
                ),
                isOnScreen: true,
                windowLayer: 0
            )

            do {
                let streamSession = try await startStream(
                    for: placeholderWindow,
                    to: clientContext.client,
                    dataPort: nil,
                    clientDisplayResolution: requestedResolution,
                    clientScaleFactor: preferredClientScaleFactor,
                    keyFrameInterval: encoderSettings?.keyFrameInterval,
                    streamScale: streamScale,
                    targetFrameRate: targetFrameRate,
                    bitDepth: encoderSettings?.bitDepth,
                    captureQueueDepth: encoderSettings?.captureQueueDepth,
                    bitrate: encoderSettings?.bitrate,
                    latencyMode: encoderSettings?.latencyMode ?? .auto,
                    performanceMode: encoderSettings?.performanceMode ?? .standard,
                    allowRuntimeQualityAdjustment: encoderSettings?.runtimeQualityAdjustmentEnabled,
                    lowLatencyHighResolutionCompressionBoost: encoderSettings?
                        .lowLatencyHighResolutionCompressionBoostEnabled ?? true,
                    disableResolutionCap: disableResolutionCap,
                    allowBestEffortRemap: false,
                    audioConfiguration: audioConfiguration
                )
                let resolvedWindow = streamSession.window
                let processID = resolvedWindow.application?.id ?? 0
                let isResizable = appStreamManager.checkWindowResizability(
                    windowID: resolvedWindow.id,
                    processID: processID
                )
                let assignedSlot = await appStreamManager.addWindowToSession(
                    bundleIdentifier: bundleID,
                    windowID: resolvedWindow.id,
                    streamID: streamSession.id,
                    title: resolvedWindow.title,
                    width: Int(resolvedWindow.frame.width),
                    height: Int(resolvedWindow.frame.height),
                    isResizable: isResizable
                )
                guard assignedSlot != nil else {
                    await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                    let reason = "window already bound to another stream"
                    _ = await appStreamManager.noteWindowStartupFailed(
                        bundleID: bundleID,
                        windowID: hiddenWindowID,
                        retryable: true,
                        reason: reason
                    )
                    MirageLogger.host("Failed to backfill hidden window \(hiddenWindowID): \(reason)")
                    break
                }
                await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: hiddenWindowID)
                await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: resolvedWindow.id)

                let added = WindowAddedToStreamMessage(
                    bundleIdentifier: bundleID,
                    streamID: streamSession.id,
                    windowID: resolvedWindow.id,
                    title: resolvedWindow.title,
                    width: Int(resolvedWindow.frame.width),
                    height: Int(resolvedWindow.frame.height),
                    isResizable: isResizable
                )
                try? await clientContext.send(.windowAddedToStream, content: added)
                await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
                await startAppStreamGovernorsIfNeeded()
                await markAppStreamInteraction(streamID: streamSession.id, reason: "hidden window backfill")
                await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "hidden window backfill")
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = detail.isEmpty ? String(describing: error) : detail
                _ = await appStreamManager.noteWindowStartupFailed(
                    bundleID: bundleID,
                    windowID: hiddenWindowID,
                    retryable: true,
                    reason: reason
                )
                MirageLogger.error(.host, error: error, message: "Failed to backfill hidden window \(hiddenWindowID): ")
                break
            }
        }
    }

    func emitWindowRemovedFromStream(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        windowID: WindowID,
        reason: WindowRemovedFromStreamMessage.RemovalReason
    ) async {
        let response = WindowRemovedFromStreamMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            reason: reason
        )
        try? await clientContext.send(.windowRemovedFromStream, content: response)
    }

    func emitWindowStreamFailed(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        reason: String
    ) async {
        let message = WindowStreamFailedMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            title: title,
            reason: reason
        )
        try? await clientContext.send(.windowStreamFailed, content: message)
    }

    private func streamFailureTitle(for window: MirageWindow, appName: String) -> String {
        if let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "\(appName) window #\(window.id)"
    }

}

#endif
