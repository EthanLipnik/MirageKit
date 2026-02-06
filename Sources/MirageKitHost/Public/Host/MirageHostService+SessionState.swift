//
//  MirageHostService+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Session state updates and window list delivery.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func startSessionStateMonitoring() async {
        if sessionStateMonitor == nil { sessionStateMonitor = SessionStateMonitor() }

        if unlockManager == nil, let sessionStateMonitor { unlockManager = UnlockManager(sessionMonitor: sessionStateMonitor) }

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

    func refreshSessionStateIfNeeded() async {
        guard let sessionStateMonitor else { return }
        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState { await handleSessionStateChange(refreshed) }
    }

    func handleSessionStateChange(_ newState: HostSessionState) async {
        sessionState = newState
        currentSessionToken = UUID().uuidString

        delegate?.hostService(self, sessionStateChanged: newState)

        for clientContext in clientsByConnection.values {
            await sendSessionState(to: clientContext)
        }

        if newState == .active {
            await stopLoginDisplayStream(newState: newState)
            await unlockManager?.releaseDisplayAssertion()
            for clientContext in clientsByConnection.values {
                await sendWindowList(to: clientContext)
            }
        } else if !clientsByConnection.isEmpty {
            await startLoginDisplayStreamIfNeeded()
        }

        await updateLightsOutState()
    }

    func sendSessionState(to clientContext: ClientContext) async {
        let message = SessionStateUpdateMessage(
            state: sessionState,
            sessionToken: currentSessionToken,
            requiresUsername: sessionState.requiresUsername,
            timestamp: Date()
        )

        do {
            try await clientContext.send(.sessionStateUpdate, content: message)
        } catch {
            MirageLogger.error(.host, "Failed to send session state: \(error)")
        }
    }

    func sendWindowList(to clientContext: ClientContext) async {
        do {
            let windowList = WindowListMessage(windows: availableWindows)
            try await clientContext.send(.windowList, content: windowList)
            MirageLogger.host("Sent window list with \(availableWindows.count) windows")
        } catch {
            MirageLogger.error(.host, "Failed to send window list: \(error)")
        }
    }

    func startSessionRefreshLoopIfNeeded() {
        guard sessionRefreshTask == nil else { return }
        guard !clientsByConnection.isEmpty else { return }

        let interval = sessionRefreshInterval
        sessionRefreshGeneration &+= 1
        let generation = sessionRefreshGeneration
        sessionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            MirageLogger.host("Session refresh loop started (interval: \(interval))")
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                if clientsByConnection.isEmpty { break }
                await refreshSessionStateIfNeeded()
            }
            if generation == sessionRefreshGeneration { sessionRefreshTask = nil }
            MirageLogger.host("Session refresh loop stopped")
        }
    }

    func stopSessionRefreshLoopIfIdle() {
        guard clientsByConnection.isEmpty else { return }
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        sessionRefreshGeneration &+= 1
    }
}
#endif
