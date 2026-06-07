//
//  MirageHostService+AppStreaming+Callbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream callbacks.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    func findClientContext(sessionID: UUID) -> ClientContext? {
        guard let clientContext = clientsBySessionID[sessionID] else { return nil }
        guard clientsByID[clientContext.client.id]?.sessionID == sessionID else { return nil }
        return clientContext
    }

    func findClientContext(clientID: UUID) -> ClientContext? {
        guard let clientContext = clientsByID[clientID] else { return nil }
        return findClientContext(sessionID: clientContext.sessionID)
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

            await appStreamManager.setOnAuxiliaryWindowDetected { [weak self] bundleID, candidate in
                Task { @MainActor in
                    await self?.handleAuxiliaryWindowDetectedFromStreamedApp(
                        bundleID: bundleID,
                        candidate: candidate
                    )
                }
            }

            await appStreamManager.setOnAuxiliaryWindowClosed { [weak self] bundleID, windowID in
                Task { @MainActor in
                    await self?.handleAuxiliaryWindowClosedFromStreamedApp(
                        bundleID: bundleID,
                        windowID: windowID
                    )
                }
            }
        }
    }

    private func refreshVisibleAppStreamCaptureCluster(
        streamID: StreamID,
        reason: String
    ) async {
        await refreshSharedDisplayAppCaptureStateBestEffort(
            streamID: streamID,
            reason: reason
        )
    }

    func handleNewWindowFromStreamedApp(bundleID: String, candidate: AppStreamWindowCandidate) async {
        let windowID = candidate.window.id
        guard let session = await appStreamManager.session(bundleIdentifier: bundleID),
              case .streaming = session.state else {
            return
        }

        if await appStreamManager.hasTrackedWindow(bundleIdentifier: bundleID, windowID: windowID) { return }

        let visibleWindowIDs = Set(session.windowStreams.keys)
        let activeOwnerClaimedWindowIDs = await platformVirtualDisplayBackend.claimedWindowIDsForActiveOwners(
            activeStreamIDs: Set(activeSessionByStreamID.keys)
        )
        let claimedWindowIDs = Set(activeStreamIDByWindowID.keys).union(activeOwnerClaimedWindowIDs)
        let disposition = Self.appLifecycleCandidateDisposition(
            candidate: candidate,
            visibleWindowIDs: visibleWindowIDs,
            claimedWindowIDs: claimedWindowIDs
        )
        guard disposition == .eligible else {
            MirageLogger.host(
                "Skipping app lifecycle candidate \(windowID) for \(bundleID): " +
                    "\(Self.appLifecycleCandidateDispositionReason(disposition)) (\(candidate.logMetadata))"
            )
            return
        }

        if await tryFulfillPendingAppWindowReplacement(
            bundleID: bundleID,
            candidate: candidate,
            session: session
        ) {
            return
        }

        await upsertHiddenInventoryWindow(bundleID: bundleID, candidate: candidate)
        await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window inventory upsert")

        MirageLogger.host("Tracked new primary window \(windowID) in hidden inventory for \(bundleID)")
    }

    func handleAuxiliaryWindowDetectedFromStreamedApp(
        bundleID: String,
        candidate: AppStreamWindowCandidate
    ) async {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleID),
              case .streaming = session.state else {
            return
        }

        guard let streamID = await resolveParentStreamIDForAuxiliaryWindow(
            bundleIdentifier: bundleID,
            candidate: candidate,
            session: session
        ) else {
            return
        }

        guard let coordinator = appAtlasCoordinatorsByClientID[session.clientID] else {
            MirageLogger.host(
                "Detected auxiliary window \(candidate.window.id) for visible app stream \(streamID) in \(bundleID); refreshing shared-display capture cluster"
            )
            await refreshVisibleAppStreamCaptureCluster(
                streamID: streamID,
                reason: "auxiliary window detected"
            )
            return
        }

        do {
            let content = try await currentCaptureShareableContent()
            let captureSource = try resolveCaptureSource(
                for: candidate.window,
                from: content,
                allowFallbackRemap: false
            )
            try await coordinator.updateAuxiliaryOverlay(
                parentStreamID: streamID,
                candidate: candidate,
                windowWrapper: SCWindowWrapper(window: captureSource.window),
                applicationWrapper: SCApplicationWrapper(application: captureSource.application),
                displayWrapper: SCDisplayWrapper(display: captureSource.display)
            )
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: bundleID,
                streamID: streamID,
                capturedClusterWindowIDs: coordinator.capturedWindowIDs(streamID: streamID)
            )

            MirageLogger.host(
                "Composited auxiliary window \(candidate.window.id) into app-atlas parent stream \(streamID) in \(bundleID)"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to composite auxiliary window into app-atlas parent: ")
        }
    }

    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleID),
              findClientContext(clientID: session.clientID) != nil else { return }

        let windowInfo = session.windowStreams[windowID]
        let hiddenWindowInfo = session.hiddenWindows[windowID]

        if hiddenWindowInfo != nil, windowInfo == nil {
            await appStreamManager.removeWindowFromSession(
                bundleIdentifier: bundleID,
                windowID: windowID
            )
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
            await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "hidden window closed")
            MirageLogger.host("Removed hidden inventory window \(windowID) from app stream \(bundleID)")
            return
        }

        guard let windowInfo else {
            return
        }

        let existingPendingClosedWindowID = pendingAppWindowReplacementsByStreamID[windowInfo.streamID]?.closedWindowID
        if existingPendingClosedWindowID == windowID {
            return
        }

        let replacement = PendingAppWindowReplacement(
            streamID: windowInfo.streamID,
            bundleIdentifier: bundleID,
            clientID: session.clientID,
            closedWindowID: windowID,
            slotStreamID: windowInfo.streamID,
            deadline: Date().addingTimeInterval(5)
        )
        beginPendingAppWindowReplacement(replacement)
        lastWindowPlacementRepairAtByWindowID.removeValue(forKey: windowID)
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window closed cooldown")
        MirageLogger.host(
            "Window \(windowID) closed for app stream \(bundleID); entered 5s replacement cooldown for stream \(windowInfo.streamID)"
        )
    }

    func handleAuxiliaryWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        if let session = await appStreamManager.session(bundleIdentifier: bundleID),
           let coordinator = appAtlasCoordinatorsByClientID[session.clientID],
           let streamID = await coordinator.removeAuxiliaryOverlay(windowID: windowID) {
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: bundleID,
                streamID: streamID,
                capturedClusterWindowIDs: coordinator.capturedWindowIDs(streamID: streamID)
            )
            MirageLogger.host(
                "Removed composited auxiliary window \(windowID) from app-atlas stream \(streamID) in \(bundleID)"
            )
            return
        }

        guard let streamID = await appStreamManager.streamIDForCapturedClusterWindow(
            bundleIdentifier: bundleID,
            windowID: windowID
        ) else {
            return
        }

        MirageLogger.host(
            "Attached auxiliary window \(windowID) closed for visible app stream \(streamID) in \(bundleID); refreshing shared-display capture cluster"
        )
        await refreshVisibleAppStreamCaptureCluster(
            streamID: streamID,
            reason: "auxiliary window closed"
        )
    }

    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleID),
              let clientContext = findClientContext(clientID: session.clientID) else {
            return
        }

        inputController.clearAllModifiers()

        let closedWindowIDs = session.windowStreams.keys.sorted(by: <)
        for streamID in session.windowStreams.values.map(\.streamID) {
            clearPendingAppWindowReplacement(streamID: streamID)
        }

        for windowID in closedWindowIDs {
            if let windowInfo = session.windowStreams[windowID],
               let streamSession = activeSessionByStreamID[windowInfo.streamID] {
                await stopStream(streamSession, minimizeWindow: false, updateAppSession: false)
            }

            await emitWindowRemovedFromStream(
                to: clientContext,
                bundleIdentifier: bundleID,
                streamID: session.windowStreams[windowID]?.streamID,
                windowID: windowID,
                reason: .appTerminated
            )
        }

        let allSessions = await appStreamManager.allSessions()
        let hasRemainingWindows = allSessions.contains { candidate in
            candidate.bundleIdentifier.lowercased() != bundleID.lowercased() &&
                candidate.clientID == session.clientID &&
                !candidate.windowStreams.isEmpty
        }

        let terminated = MirageWire.AppTerminatedMessage(
            bundleIdentifier: bundleID,
            closedWindowIDs: closedWindowIDs,
            hasRemainingWindows: hasRemainingWindows
        )
        do {
            try await clientContext.send(.appTerminated, content: terminated)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send appTerminated: ")
        }

        await appStreamManager.endSession(bundleIdentifier: bundleID)
        await restoreStageManagerAfterAppStreamingIfNeeded()

        MirageLogger.host("App \(bundleID) terminated, ended session")
    }

    func emitWindowRemovedFromStream(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        streamID: StreamID? = nil,
        windowID: WindowID,
        reason: MirageWire.WindowRemovedFromStreamMessage.RemovalReason
    ) async {
        let appSessionID = await appStreamManager.session(bundleIdentifier: bundleIdentifier)?.id
        let response = MirageWire.WindowRemovedFromStreamMessage(
            bundleIdentifier: bundleIdentifier,
            appSessionID: appSessionID,
            streamID: streamID,
            windowID: windowID,
            reason: reason
        )
        do {
            try await clientContext.send(.windowRemovedFromStream, content: response)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send windowRemovedFromStream: ")
        }
    }

    func emitWindowStreamFailed(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        windowID: WindowID,
        title: String?,
        reason: String,
        failureCode: MirageWire.WindowStreamFailedMessage.FailureCode = .unknown,
        userMessage: String
    ) async {
        let message = MirageWire.WindowStreamFailedMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            title: title,
            reason: reason,
            failureCode: failureCode,
            userMessage: userMessage
        )
        do {
            try await clientContext.send(.windowStreamFailed, content: message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send windowStreamFailed: ")
        }
    }
}

#endif
