//
//  MirageHostService+AppStreaming+Replacement.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Clears pending replacement state for a closed app-window stream.
    func clearPendingAppWindowReplacement(streamID: StreamID) {
        pendingAppWindowReplacementsByStreamID.removeValue(forKey: streamID)
        pendingAppWindowReplacementTasksByStreamID.removeValue(forKey: streamID)?.cancel()
    }

    /// Starts the cooldown window during which a new app window can replace a closed one.
    func beginPendingAppWindowReplacement(_ replacement: PendingAppWindowReplacement) {
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

    /// Attempts to bind a newly discovered window into a pending replacement slot.
    func tryFulfillPendingAppWindowReplacement(
        bundleID: String,
        candidate: AppStreamWindowCandidate,
        session: MirageAppStreamSession
    ) async -> Bool {
        let pendingReplacement = pendingAppWindowReplacementsByStreamID.values
            .filter { replacement in
                replacement.bundleIdentifier.lowercased() == bundleID.lowercased() &&
                    replacement.clientID == session.clientID
            }
            .min { lhs, rhs in
                if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
                return lhs.streamID < rhs.streamID
            }

        guard let pendingReplacement else { return false }
        guard activeSessionByStreamID[pendingReplacement.streamID] != nil else {
            clearPendingAppWindowReplacement(streamID: pendingReplacement.streamID)
            return false
        }

        let windowID = candidate.window.id
        await upsertHiddenInventoryWindow(bundleID: bundleID, candidate: candidate)

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

    /// Adds a primary window candidate to hidden inventory with current resizability metadata.
    func upsertHiddenInventoryWindow(
        bundleID: String,
        candidate: AppStreamWindowCandidate
    ) async {
        let mirageWindow = candidate.window
        let processID = mirageWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
            processID: processID
        )
        await appStreamManager.upsertHiddenWindow(
            bundleIdentifier: bundleID,
            windowID: mirageWindow.id,
            title: mirageWindow.title,
            width: Int(mirageWindow.frame.width),
            height: Int(mirageWindow.frame.height),
            isResizable: isResizable
        )
    }

    /// Expires an unfulfilled app-window replacement and stops the old stream if it is still active.
    func expirePendingAppWindowReplacement(streamID: StreamID) async {
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
        if let session = await appStreamManager.session(bundleIdentifier: pending.bundleIdentifier) {
            await sendAppWindowInventoryUpdate(bundleIdentifier: pending.bundleIdentifier, clientID: session.clientID)
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: pending.bundleIdentifier,
                reason: "window close cooldown expired"
            )
        }
        MirageLogger.host(
            "Pending app-window replacement expired; stopped stream \(streamID) for window \(pending.closedWindowID)"
        )
    }
}

#endif
