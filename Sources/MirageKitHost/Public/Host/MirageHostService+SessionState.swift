//
//  MirageHostService+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Session state updates and window list delivery.
//

import Foundation
import MirageBootstrapShared
import MirageKit

#if os(macOS)
extension MirageHostService {
    nonisolated func handleSessionStateMonitorUpdate(_ newState: LoomSessionAvailability) {
        Task { @MainActor [weak self] in
            await self?.handleSessionStateChange(newState)
        }
    }
}

@MainActor
extension MirageHostService {
    func startSessionStateMonitoring() async {
        if sessionStateMonitor == nil { sessionStateMonitor = SessionStateMonitor() }

        if unlockManager == nil, let sessionStateMonitor {
            unlockManager = UnlockManager(
                sessionMonitor: sessionStateMonitor,
                environment: .hostService
            )
        }

        guard let sessionStateMonitor else { return }

        await sessionStateMonitor.start(onStateChange: handleSessionStateMonitorUpdate)

        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState { await handleSessionStateChange(refreshed) }

        startSessionRefreshLoopIfNeeded()
    }

    func refreshSessionStateIfNeeded() async {
        guard let sessionStateMonitor else { return }
        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState { await handleSessionStateChange(refreshed) }
    }

    func handleSessionStateChange(_ newState: LoomSessionAvailability) async {
        sessionState = newState
        currentSessionToken = UUID().uuidString

        delegate?.hostService(self, sessionStateChanged: newState)

        for clientContext in clientsBySessionID.values {
            await sendSessionState(to: clientContext)
        }

        if newState == .ready {
            await stopLoginDisplayStream(newState: newState)
            await unlockManager?.releaseDisplayAssertion()
            for clientContext in clientsBySessionID.values {
                await sendWindowList(to: clientContext)
            }
            await syncAppListRequestDeferralForInteractiveWorkload()
        } else if !clientsBySessionID.isEmpty {
            await startLoginDisplayStreamIfNeeded()
        }

        syncSharedClipboardState(reason: "session_state_changed")
        await updateLightsOutState()
    }

    func sendSessionState(to clientContext: ClientContext) async {
        let message = SessionStateUpdateMessage(
            state: sessionState,
            sessionToken: currentSessionToken,
            requiresUserIdentifier: sessionState.requiresUserIdentifier,
            timestamp: Date()
        )

        do {
            try await clientContext.send(.sessionStateUpdate, content: message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send session state: ")
        }
    }

    func sendWindowList(to clientContext: ClientContext) async {
        do {
            let windowList = WindowListMessage(windows: availableWindows)
            try await clientContext.send(.windowList, content: windowList)
            MirageLogger.host("Sent window list with \(availableWindows.count) windows")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send window list: ")
        }
    }

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
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                if clientsBySessionID.isEmpty { break }
                await refreshSessionStateIfNeeded()
            }
            if generation == sessionRefreshGeneration { sessionRefreshTask = nil }
            MirageLogger.host("Session refresh loop stopped")
        }
    }

    func stopSessionRefreshLoopIfIdle() {
        guard clientsBySessionID.isEmpty || connectedClients.isEmpty else { return }
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        sessionRefreshGeneration &+= 1
    }
}
#endif
