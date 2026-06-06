//
//  MirageHostService+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Session state updates and window list delivery.
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
import Loom
import MirageBootstrapShared

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Starts monitoring login/session availability and sends the initial state to connected clients.
    func startSessionStateMonitoring() async {
        if sessionStateMonitor == nil { sessionStateMonitor = SessionStateMonitor() }

        guard let sessionStateMonitor else { return }

        await sessionStateMonitor.start { [weak self] newState in
            Task { @MainActor [weak self] in
                await self?.handleSessionStateChange(newState)
            }
        }

        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState { await handleSessionStateChange(refreshed) }

        startSessionRefreshLoopIfNeeded()
    }

    /// Refreshes session availability if a monitor is active.
    func refreshSessionStateIfNeeded() async {
        guard let sessionStateMonitor else { return }
        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState { await handleSessionStateChange(refreshed) }
    }

    /// Applies a session availability change and broadcasts dependent host state.
    func handleSessionStateChange(_ newState: LoomSessionAvailability) async {
        let availability = MirageWire.MirageHostSessionAvailability(loomAvailability: newState)
        mirageSessionAvailability = availability
        currentSessionToken = UUID().uuidString

        delegate?.sessionAvailabilityDidChange(availability)
        delegate?.sessionStateDidChange(newState)

        for clientContext in clientsBySessionID.values {
            await sendSessionState(to: clientContext)
        }

        if mirageSessionAvailability == .ready {
            for clientContext in clientsBySessionID.values {
                await sendWindowList(to: clientContext)
            }
            await syncAppListRequestDeferralForInteractiveWorkload()
            await resumePendingLockedAppStreamIntentsIfNeeded()
        }

        syncSharedClipboardState()
        await updateLightsOutState()
    }

    /// Sends the current host session availability to a client.
    func sendSessionState(to clientContext: ClientContext) async {
        let availability = mirageSessionAvailability
        let message = MirageWire.SessionStateUpdateMessage(
            state: availability,
            sessionToken: currentSessionToken,
            requiresUserIdentifier: availability.requiresUserIdentifier
        )

        do {
            try await clientContext.send(.sessionStateUpdate, content: message)
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Session state update",
                sessionID: clientContext.sessionID
            )
        }
    }

    /// Sends the current window catalog to a client.
    func sendWindowList(to clientContext: ClientContext) async {
        do {
            let windowList = MirageWire.WindowListMessage(windows: availableWindows)
            try await clientContext.send(.windowList, content: windowList)
            MirageLogger.host("Sent window list with \(availableWindows.count) windows")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send window list: ")
        }
    }

    /// Starts the periodic session refresh loop while clients remain connected.
    func startSessionRefreshLoopIfNeeded() {
        guard sessionRefreshTask == nil else { return }
        guard !clientsBySessionID.isEmpty else { return }

        let interval = sessionRefreshInterval
        sessionRefreshGeneration &+= 1
        let generation = sessionRefreshGeneration
        sessionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            MirageLogger.host("Session refresh loop started (interval: \(interval))")
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                if clientsBySessionID.isEmpty { break }
                await refreshSessionStateIfNeeded()
            }
            if generation == sessionRefreshGeneration { sessionRefreshTask = nil }
            MirageLogger.host("Session refresh loop stopped")
        }
    }

    /// Stops periodic session refreshes once no clients need them.
    func stopSessionRefreshLoopIfIdle() {
        guard clientsBySessionID.isEmpty || connectedClients.isEmpty else { return }
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        sessionRefreshGeneration &+= 1
    }
}
#endif
