//
//  MirageHostService+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Security

#if os(macOS)

// MARK: - Session State Management

extension MirageHostService {
    /// Start monitoring session state for lock/unlock detection
    func startSessionStateMonitoring() async {
        sessionStateMonitor = SessionStateMonitor()
        unlockManager = UnlockManager(sessionMonitor: sessionStateMonitor!)

        // Generate initial session token
        currentSessionToken = generateSessionToken()

        // Get initial state
        let initialState = await sessionStateMonitor!.refreshState()
        sessionState = initialState

        if sessionState.requiresUnlock, !clientsByConnection.isEmpty {
            await startLoginDisplayStreamIfNeeded()
        }

        // Start monitoring with callback
        await sessionStateMonitor!.start { @Sendable [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleSessionStateChange(newState)
            }
        }

        MirageLogger.host("Session state monitoring started, initial state: \(sessionState)")
    }

    /// Handle session state change
    func handleSessionStateChange(_ newState: HostSessionState) async {
        let oldState = sessionState
        sessionState = newState

        // Generate new session token on state change
        currentSessionToken = generateSessionToken()

        MirageLogger.host("Session state changed: \(oldState) -> \(newState)")

        // Notify delegate
        delegate?.hostService(self, sessionStateChanged: newState)

        // Broadcast to all connected clients
        await broadcastSessionState()

        if newState.requiresUnlock {
            if !clientsByConnection.isEmpty {
                await startLoginDisplayStreamIfNeeded()
            }
        } else {
            await stopLoginDisplayStream(newState: newState)
        }

        // If state changed to active (user logged in), send window list to all connected clients
        if newState == .active && oldState != .active {
            // Release unlock manager resources
            if let unlockManager {
                await unlockManager.releaseDisplayAssertion()
            }

            // Send window list to all connected clients
            for clientContext in clientsByConnection.values {
                await sendWindowList(to: clientContext)
            }
        }
    }

    /// Generate a cryptographically random session token
    func generateSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Broadcast current session state to all connected clients
    func broadcastSessionState() async {
        let message = SessionStateUpdateMessage(
            state: sessionState,
            sessionToken: currentSessionToken,
            requiresUsername: sessionState.requiresUsername,
            timestamp: Date()
        )

        for clientContext in clientsByConnection.values {
            do {
                try await clientContext.send(.sessionStateUpdate, content: message)
            } catch {
                MirageLogger.error(.host, "Failed to send session state to client: \(error)")
            }
        }
    }
}

#endif
