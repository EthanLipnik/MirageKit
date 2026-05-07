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
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    enum WindowCloseCooldownDecision: Equatable, Sendable {
        case enterCooldown
        case ignoreDuplicate
    }

    enum AppLifecycleCandidateDisposition: String, Equatable, Sendable {
        case eligible
        case auxiliary
        case visibleStreamBound
        case claimedByActiveStream
    }

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

    nonisolated static func windowCloseCooldownDecision(
        existingPendingClosedWindowID: WindowID?,
        closingWindowID: WindowID
    ) -> WindowCloseCooldownDecision {
        if existingPendingClosedWindowID == closingWindowID {
            return .ignoreDuplicate
        }
        return .enterCooldown
    }

    nonisolated static func appLifecycleCandidateDisposition(
        candidate: AppStreamWindowCandidate,
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>
    ) -> AppLifecycleCandidateDisposition {
        guard candidate.classification == .primary else { return .auxiliary }
        if visibleWindowIDs.contains(candidate.window.id) {
            return .visibleStreamBound
        }
        if claimedWindowIDs.contains(candidate.window.id) {
            return .claimedByActiveStream
        }
        return .eligible
    }

    nonisolated static func appLifecycleCandidateDispositionReason(
        _ disposition: AppLifecycleCandidateDisposition
    ) -> String {
        switch disposition {
        case .eligible:
            "eligible"
        case .auxiliary:
            "auxiliary child window"
        case .visibleStreamBound:
            "already bound to a visible stream"
        case .claimedByActiveStream:
            "claimed by an active stream owner"
        }
    }

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
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
              case .streaming = session.state else {
            return
        }

        if await appStreamManager.hasTrackedWindow(bundleIdentifier: bundleID, windowID: windowID) { return }

        let visibleWindowIDs = Set(session.windowStreams.keys)
        let activeOwnerClaimedWindowIDs = await WindowSpaceManager.shared.claimedWindowIDsForActiveOwners(
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

        let mirageWindow = candidate.window
        let processID = mirageWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
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
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window inventory upsert")

        MirageLogger.host("Tracked new primary window \(windowID) in hidden inventory for \(bundleID)")
    }

    func handleAuxiliaryWindowDetectedFromStreamedApp(
        bundleID: String,
        candidate: AppStreamWindowCandidate
    ) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
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
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
                capturedClusterWindowIDs: await coordinator.capturedWindowIDs(streamID: streamID)
            )

            MirageLogger.host(
                "Composited auxiliary window \(candidate.window.id) into app-atlas parent stream \(streamID) in \(bundleID)"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to composite auxiliary window into app-atlas parent: ")
        }
    }

    func handleWindowClosedFromStreamedApp(bundleID: String, windowID: WindowID) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
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
        if Self.windowCloseCooldownDecision(
            existingPendingClosedWindowID: existingPendingClosedWindowID,
            closingWindowID: windowID
        ) == .ignoreDuplicate {
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
        if let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
           let coordinator = appAtlasCoordinatorsByClientID[session.clientID],
           let streamID = await coordinator.removeAuxiliaryOverlay(windowID: windowID) {
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: bundleID,
                streamID: streamID,
                capturedClusterWindowIDs: await coordinator.capturedWindowIDs(streamID: streamID)
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

    private func resolveParentStreamIDForAuxiliaryWindow(
        bundleIdentifier: String,
        candidate: AppStreamWindowCandidate,
        session: MirageAppStreamSession
    ) async -> StreamID? {
        if let parentWindowID = candidate.parentWindowID {
            let streamIDForClusterParent = await appStreamManager.streamIDForCapturedClusterWindow(
                bundleIdentifier: bundleIdentifier,
                windowID: parentWindowID
            )
            let directParentStreamID = await appStreamManager.streamIDForWindow(
                bundleIdentifier: bundleIdentifier,
                windowID: parentWindowID
            )
            if let streamID = streamIDForClusterParent ?? directParentStreamID {
                return streamID
            }
        }

        let visibleStreamIDs = Set(session.windowStreams.values.map(\.streamID))
        if candidate.isFocused || candidate.isMain || candidate.isModal {
            let activeStreams = await appStreamManager.streamActivityMap(bundleIdentifier: bundleIdentifier)
            if let activeStreamID = activeStreams
                .filter({ entry in entry.value && visibleStreamIDs.contains(entry.key) })
                .map(\.key)
                .sorted()
                .first {
                return activeStreamID
            }
        }

        let visibleParentCandidates = session.windowStreams.compactMap { _, info -> (streamID: StreamID, frame: CGRect)? in
            guard let activeSession = activeSessionByStreamID[info.streamID] else { return nil }
            return (
                streamID: info.streamID,
                frame: currentWindowFrame(for: activeSession.window.id) ?? activeSession.window.frame
            )
        }
        return Self.bestAuxiliaryParentStream(
            auxiliaryFrame: candidate.window.frame,
            visibleParents: visibleParentCandidates
        )
    }

    nonisolated static func bestAuxiliaryParentStream(
        auxiliaryFrame: CGRect,
        visibleParents: [(streamID: StreamID, frame: CGRect)]
    ) -> StreamID? {
        guard !visibleParents.isEmpty else { return nil }
        let auxiliaryCenter = CGPoint(x: auxiliaryFrame.midX, y: auxiliaryFrame.midY)
        return visibleParents.sorted { lhs, rhs in
            let lhsOverlap = overlapArea(lhs.frame, auxiliaryFrame)
            let rhsOverlap = overlapArea(rhs.frame, auxiliaryFrame)
            if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }

            let lhsDistance = squaredDistance(from: auxiliaryCenter, to: CGPoint(x: lhs.frame.midX, y: lhs.frame.midY))
            let rhsDistance = squaredDistance(from: auxiliaryCenter, to: CGPoint(x: rhs.frame.midX, y: rhs.frame.midY))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.streamID < rhs.streamID
        }
        .first?
        .streamID
    }

    private nonisolated static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return (dx * dx) + (dy * dy)
    }

    func handleStreamedAppTerminated(bundleID: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleID),
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

    func clearPendingAppWindowReplacement(streamID: StreamID) {
        pendingAppWindowReplacementsByStreamID.removeValue(forKey: streamID)
        pendingAppWindowReplacementTasksByStreamID.removeValue(forKey: streamID)?.cancel()
    }

    private func beginPendingAppWindowReplacement(_ replacement: PendingAppWindowReplacement) {
        clearPendingAppWindowReplacement(streamID: replacement.streamID)
        pendingAppWindowReplacementsByStreamID[replacement.streamID] = replacement

        let streamID = replacement.streamID
        let cooldown = appWindowReplacementCooldownDuration
        pendingAppWindowReplacementTasksByStreamID[streamID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: cooldown)
            } catch {
                return
            }
            await self?.expirePendingAppWindowReplacement(streamID: streamID)
        }
    }

    private func tryFulfillPendingAppWindowReplacement(
        bundleID: String,
        candidate: AppStreamWindowCandidate,
        session: MirageAppStreamSession
    ) async -> Bool {
        let pendingReplacement = pendingAppWindowReplacementsByStreamID.values
            .filter { replacement in
                replacement.bundleIdentifier.lowercased() == bundleID.lowercased() &&
                    replacement.clientID == session.clientID
            }
            .sorted { lhs, rhs in
                if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
                return lhs.streamID < rhs.streamID
            }
            .first

        guard let pendingReplacement else { return false }
        guard activeSessionByStreamID[pendingReplacement.streamID] != nil else {
            clearPendingAppWindowReplacement(streamID: pendingReplacement.streamID)
            return false
        }

        let windowID = candidate.window.id
        let processID = candidate.window.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
            processID: processID
        )
        await appStreamManager.upsertHiddenWindow(
            bundleIdentifier: bundleID,
            windowID: windowID,
            title: candidate.window.title,
            width: Int(candidate.window.frame.width),
            height: Int(candidate.window.frame.height),
            isResizable: isResizable
        )

        let swapResult = await performAppWindowSwap(
            bundleIdentifier: bundleID,
            targetSlotStreamID: pendingReplacement.slotStreamID,
            targetWindowID: windowID,
            clientID: session.clientID
        )
        guard swapResult.success else {
            let reason = swapResult.reason ?? "unknown reason"
            MirageLogger.host(
                "Failed to fulfill pending app-window replacement for stream \(pendingReplacement.streamID): \(reason)"
            )
            await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
            return false
        }

        clearPendingAppWindowReplacement(streamID: pendingReplacement.streamID)
        await appStreamManager.removeWindowFromSession(
            bundleIdentifier: bundleID,
            windowID: pendingReplacement.closedWindowID
        )
        await appStreamManager.noteWindowStartupSucceeded(bundleID: bundleID, windowID: windowID)
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleID, clientID: session.clientID)
        await markAppStreamInteraction(
            streamID: pendingReplacement.streamID,
            reason: "window close replacement"
        )
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleID, reason: "window close replacement")
        MirageLogger.host(
            "Rebound stream \(pendingReplacement.streamID) from closed window \(pendingReplacement.closedWindowID) to new window \(windowID)"
        )
        return true
    }

    private func expirePendingAppWindowReplacement(streamID: StreamID) async {
        guard let pending = pendingAppWindowReplacementsByStreamID[streamID] else { return }
        guard Date() >= pending.deadline else { return }
        clearPendingAppWindowReplacement(streamID: streamID)

        guard let streamSession = activeSessionByStreamID[streamID] else {
            await appStreamManager.removeWindowFromSession(
                bundleIdentifier: pending.bundleIdentifier,
                windowID: pending.closedWindowID
            )
            await endAppSessionIfIdle(bundleIdentifier: pending.bundleIdentifier)
            return
        }

        await stopStream(streamSession, minimizeWindow: false)
        if let session = await appStreamManager.getSession(bundleIdentifier: pending.bundleIdentifier) {
            await sendAppWindowInventoryUpdate(bundleIdentifier: pending.bundleIdentifier, clientID: session.clientID)
            await recomputeAppSessionBitrateBudget(bundleIdentifier: pending.bundleIdentifier, reason: "window close cooldown expired")
        }
        MirageLogger.host(
            "Pending app-window replacement expired; stopped stream \(streamID) for window \(pending.closedWindowID)"
        )
    }

    func emitWindowRemovedFromStream(
        to clientContext: ClientContext,
        bundleIdentifier: String,
        streamID: StreamID? = nil,
        windowID: WindowID,
        reason: WindowRemovedFromStreamMessage.RemovalReason
    ) async {
        let appSessionID = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier)?.id
        let response = WindowRemovedFromStreamMessage(
            bundleIdentifier: bundleIdentifier,
            appSessionID: appSessionID,
            streamID: streamID,
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
        reason: String,
        failureCode: WindowStreamFailedMessage.FailureCode = .unknown,
        userMessage: String? = nil
    ) async {
        let message = WindowStreamFailedMessage(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            title: title,
            reason: reason,
            failureCode: failureCode,
            userMessage: userMessage
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
