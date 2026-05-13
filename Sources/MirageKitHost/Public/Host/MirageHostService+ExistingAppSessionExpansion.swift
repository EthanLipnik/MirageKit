//
//  MirageHostService+ExistingAppSessionExpansion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Expands an existing app session when a client selects an already-streaming app.
    func handleExistingAppSessionExpansionIfNeeded(
        _ request: SelectAppExistingSessionExpansionRequest
    ) async -> Bool {
        guard let existingSession = await appStreamManager.session(bundleIdentifier: request.app.bundleIdentifier),
              !existingSession.reservationExpired else {
            return false
        }

        if existingSession.clientID == request.client.id {
            await appStreamManager.raiseMaxVisibleSlots(
                bundleIdentifier: request.app.bundleIdentifier,
                to: request.maxVisibleSlots
            )
        }
        let hasVisibleSlotCapacity = await appStreamManager.hasVisibleSlotCapacity(
            bundleIdentifier: request.app.bundleIdentifier
        )
        guard existingSession.clientID == request.client.id else {
            sendAppSelectionError(
                to: request.clientContext,
                code: .windowNotFound,
                message: "\(request.app.name) is already being streamed to another client"
            )
            return true
        }
        guard existingSession.state == .streaming else {
            sendAppSelectionError(
                to: request.clientContext,
                code: .windowNotFound,
                message: "\(request.app.name) is still starting; try again in a moment."
            )
            return true
        }
        guard hasVisibleSlotCapacity else {
            sendAppSelectionError(
                to: request.clientContext,
                code: .windowNotFound,
                message: "Max app windows reached for \(request.app.name)"
            )
            return true
        }
        guard !disconnectingClientIDs.contains(existingSession.clientID),
              let existingClientContext = findClientContext(clientID: existingSession.clientID) else {
            sendAppSelectionError(
                to: request.clientContext,
                code: .windowNotFound,
                message: "Client context unavailable for \(request.app.name)"
            )
            return true
        }

        let expansionResult = await startAdditionalStreamForExistingAppSession(
            app: request.app,
            session: existingSession,
            clientContext: existingClientContext,
            selectRequest: request.selectRequest,
            targetFrameRate: request.targetFrameRate,
            mediaMaxPacketSize: request.mediaMaxPacketSize
        )
        switch expansionResult {
        case let .success(added):
            do {
                try await existingClientContext.send(.windowAddedToStream, content: added)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send windowAddedToStream: ")
            }
            await sendAppWindowInventoryUpdate(
                bundleIdentifier: request.app.bundleIdentifier,
                clientID: request.client.id
            )
            await refreshAppStreamGovernors(reason: "event")
            await markAppStreamInteraction(streamID: added.streamID, reason: "select app expansion")
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: request.app.bundleIdentifier,
                reason: "selectApp existing session expansion"
            )
            MirageLogger.host(
                "Expanded existing app stream \(request.app.bundleIdentifier) with window \(added.windowID) stream \(added.streamID)"
            )
        case .cancelled:
            MirageLogger.host(
                "Cancelled existing app-stream expansion for \(request.app.bundleIdentifier) request=\(request.selectRequest.startupRequestID.uuidString)"
            )
        case let .failure(reason):
            sendAppSelectionError(
                to: request.clientContext,
                code: .windowNotFound,
                message: reason
            )
        }
        return true
    }

    /// Sends the initial app-stream started response and starts session maintenance.
    func sendInitialAppStreamStarted(
        app: MirageInstalledApp,
        request: SelectAppMessage,
        startupWindows: [InitialStartedAppWindow],
        clientContext: ClientContext
    ) async throws {
        await appStreamManager.markSessionStreaming(app.bundleIdentifier)

        let sortedStartupWindows = startupWindows.sorted { $0.streamID < $1.streamID }
        let response = AppStreamStartedMessage(
            appSessionID: request.appSessionID,
            startupRequestID: request.startupRequestID,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            windows: sortedStartupWindows.map(\.asWireWindow),
            atlasLayouts: sortedStartupWindows.last?.atlasLayouts
        )
        let responseMessage = try ControlMessage(type: .appStreamStarted, content: response)
        clientContext.sendBestEffort(responseMessage)
        await sendAppWindowInventoryUpdate(
            bundleIdentifier: app.bundleIdentifier,
            clientID: clientContext.client.id
        )
        await refreshAppStreamGovernors(reason: "event")
        await recomputeAppSessionBitrateBudget(bundleIdentifier: app.bundleIdentifier, reason: "appStreamStarted")
    }

    /// Starts one additional visible stream for an existing app session.
    func startAdditionalStreamForExistingAppSession(
        app: MirageInstalledApp,
        session: MirageAppStreamSession,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        mediaMaxPacketSize: Int
    ) async -> ExistingSessionWindowStartResult {
        let normalizedBundleID = app.bundleIdentifier.lowercased()
        guard !isStreamSetupCancelled(
            clientSessionID: clientContext.sessionID,
            startupRequestID: selectRequest.startupRequestID
        ) else {
            return .cancelled
        }
        let catalog: [AppStreamWindowCandidate]
        do {
            catalog = try await AppStreamWindowCatalog.catalog(for: [app.bundleIdentifier])[normalizedBundleID] ?? []
        } catch {
            return .failure("Failed to enumerate windows for \(app.name): \(error.localizedDescription)")
        }

        let selectedCandidate = await selectExistingSessionExpansionCandidate(
            session: session,
            catalog: catalog
        )
        guard let selectedCandidate else {
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                return .cancelled
            }
            await appStreamManager.requestNewWindow(bundleIdentifier: app.bundleIdentifier, path: app.path)
            MirageLogger.host(
                "Existing app-stream expansion requested a new window for \(app.bundleIdentifier) because no unclaimed eligible windows were available"
            )
            do {
                try await Task.sleep(for: Self.initialAppWindowDiscoveryRetryDelay(afterAttempt: 1))
            } catch {
                return .cancelled
            }
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                return .cancelled
            }
            let refreshedCatalog: [AppStreamWindowCandidate]
            do {
                refreshedCatalog = try await AppStreamWindowCatalog.catalog(for: [app.bundleIdentifier])[normalizedBundleID] ?? []
            } catch {
                return .failure("Failed to enumerate windows for \(app.name): \(error.localizedDescription)")
            }
            guard let refreshedCandidate = await selectExistingSessionExpansionCandidate(
                session: session,
                catalog: refreshedCatalog
            ) else {
                return .failure("No additional \(app.name) windows are available to stream.")
            }
            return await startAdditionalStreamForExistingAppSessionCandidate(
                app: app,
                session: session,
                clientContext: clientContext,
                selectRequest: selectRequest,
                targetFrameRate: targetFrameRate,
                mediaMaxPacketSize: mediaMaxPacketSize,
                selectedCandidate: refreshedCandidate
            )
        }

        return await startAdditionalStreamForExistingAppSessionCandidate(
            app: app,
            session: session,
            clientContext: clientContext,
            selectRequest: selectRequest,
            targetFrameRate: targetFrameRate,
            mediaMaxPacketSize: mediaMaxPacketSize,
            selectedCandidate: selectedCandidate
        )
    }

    /// Chooses an unclaimed candidate window for existing app-session expansion.
    func selectExistingSessionExpansionCandidate(
        session: MirageAppStreamSession,
        catalog: [AppStreamWindowCandidate]
    ) async -> AppStreamWindowCandidate? {
        let visibleWindowIDs = Set(session.windowStreams.keys)
        let activeOwnerClaimedWindowIDs = await WindowSpaceManager.shared.claimedWindowIDsForActiveOwners(
            activeStreamIDs: Set(activeSessionByStreamID.keys)
        )
        let claimedWindowIDs = visibleWindowIDs.union(activeOwnerClaimedWindowIDs)
        let candidates = AppStreamWindowCatalog.startupCandidateSelection(from: catalog)
        return Self.lifecycleStartupEligibleCandidates(
            from: candidates,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs
        ).first
    }

    /// Starts capture for a selected expansion candidate and registers it with the app session.
    func startAdditionalStreamForExistingAppSessionCandidate(
        app: MirageInstalledApp,
        session: MirageAppStreamSession,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        mediaMaxPacketSize: Int,
        selectedCandidate: AppStreamWindowCandidate
    ) async -> ExistingSessionWindowStartResult {
        let selectedWindow = selectedCandidate.window
        let existingStreamID = session.windowStreams.values.map(\.streamID).max()
        let existingContext = existingStreamID.flatMap { streamsByID[$0] }
        let encoderSettings = await existingContext?.encoderSettings
        let inheritedTargetFrameRate = await existingContext?.encoderConfig.targetFrameRate
        let requestedBitrate: Int? = if let sharedBudgetBps = session.bitrateBudgetBps {
            max(1_000_000, sharedBudgetBps / max(1, session.windowStreams.count + 1))
        } else {
            encoderSettings?.bitrate ?? selectRequest.bitrate
        }
        let preferredSlotIndex = await appStreamManager.availableVisibleSlotIndex(bundleIdentifier: app.bundleIdentifier)

        do {
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                return .cancelled
            }
            await prepareWindowForStreamingIfNeeded(
                selectedWindow,
                reason: "existing-session expansion"
            )
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                return .cancelled
            }
            let started = try await startAppAtlasWindowCapture(
                app: app,
                window: selectedWindow,
                clientContext: clientContext,
                selectRequest: selectRequest,
                targetFrameRate: inheritedTargetFrameRate ?? targetFrameRate,
                requestedBitrate: requestedBitrate,
                mediaMaxPacketSize: mediaMaxPacketSize
            )
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                await stopStream(started.session, minimizeWindow: false, updateAppSession: false)
                return .cancelled
            }
            let streamSession = started.session
            let attachment = started.attachment
            let resolvedWindowID = attachment.windowID

            guard let confirmedSession = await appStreamManager.session(bundleIdentifier: app.bundleIdentifier),
                  case .streaming = confirmedSession.state,
                  confirmedSession.clientID == session.clientID else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return .failure("App session is no longer active for \(app.name).")
            }

            let processID = streamSession.window.application?.id ?? selectedWindow.application?.id ?? 0
            let isResizable = appStreamManager.checkWindowResizability(
                processID: processID
            )
            let assignedSlot = await appStreamManager.addWindowToSession(
                bundleIdentifier: app.bundleIdentifier,
                windowID: resolvedWindowID,
                streamID: streamSession.id,
                title: attachment.title,
                width: attachment.width,
                height: attachment.height,
                isResizable: isResizable,
                slotIndex: preferredSlotIndex,
                mediaStreamID: attachment.mediaStreamID,
                atlasRegion: attachment.atlasRegion
            )
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: selectRequest.startupRequestID
            ) else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                await appStreamManager.removeWindowFromSession(
                    bundleIdentifier: app.bundleIdentifier,
                    windowID: resolvedWindowID
                )
                return .cancelled
            }
            guard assignedSlot != nil else {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
                return .failure("No visible slot is available for another \(app.name) window.")
            }
            if let context = streamsByID[streamSession.id] {
                await appStreamManager.setCapturedClusterWindowIDs(
                    bundleIdentifier: app.bundleIdentifier,
                    streamID: streamSession.id,
                    capturedClusterWindowIDs: context.capturedWindowClusterWindowIDs
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
                    appSessionID: session.id,
                    streamID: streamSession.id,
                    mediaStreamID: attachment.mediaStreamID,
                    windowID: resolvedWindowID,
                    title: attachment.title,
                    width: attachment.width,
                    height: attachment.height,
                    isResizable: isResizable,
                    atlasRegion: attachment.atlasRegion,
                    atlasLayouts: attachment.atlasLayouts
                )
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? String(describing: error) : detail
            await appStreamManager.recordWindowStartupFailure(
                bundleID: app.bundleIdentifier,
                windowID: selectedWindow.id,
                retryable: false
            )
            return .failure("Failed to start additional \(app.name) window: \(reason)")
        }
    }
}

#endif
