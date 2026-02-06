//
//  MirageHostService+Unlock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)

// MARK: - Unlock Handling

extension MirageHostService {
    /// Handle an unlock request from a client
    func handleUnlockRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        MirageLogger.host("Received unlock request from \(client.name)")

        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            MirageLogger.error(.host, "No client context for unlock request")
            return
        }

        // Check if remote unlock is enabled
        guard remoteUnlockEnabled else {
            let response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: nil,
                error: UnlockError(code: .notSupported, message: "Remote unlock is disabled on this host"),
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
            try? await clientContext.send(.unlockResponse, content: response)
            return
        }

        // Ask delegate if this client is authorized to unlock
        let isAuthorized = delegate?.hostService(self, shouldAllowUnlockFrom: client) ?? true
        guard isAuthorized else {
            let response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: nil,
                error: UnlockError(code: .notAuthorized, message: "Client not authorized for unlock"),
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
            try? await clientContext.send(.unlockResponse, content: response)
            return
        }

        // Decode the request
        let request: UnlockRequestMessage
        do {
            request = try message.decode(UnlockRequestMessage.self)
        } catch {
            MirageLogger.error(.host, "Failed to decode unlock request: \(error)")
            let response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: nil,
                error: UnlockError(code: .internalError, message: "Invalid request format"),
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
            try? await clientContext.send(.unlockResponse, content: response)
            return
        }

        // Validate session token
        guard request.sessionToken == currentSessionToken else {
            let response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: currentSessionToken,
                error: UnlockError(code: .sessionExpired, message: "Session token expired. Please try again."),
                canRetry: true,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
            try? await clientContext.send(.unlockResponse, content: response)
            return
        }

        // Attempt unlock
        guard let unlockManager else {
            MirageLogger.error(.host, "Unlock manager not initialized")
            return
        }

        let (result, retriesRemaining, retryAfter) = await unlockManager.attemptUnlock(
            username: request.username,
            password: request.password,
            requiresUsername: sessionState.requiresUsername,
            clientID: client.id
        )

        // Build response based on result
        let response: UnlockResponseMessage
        switch result {
        case .success:
            response = UnlockResponseMessage(
                success: true,
                newState: .active,
                newSessionToken: currentSessionToken,
                error: nil,
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
            MirageLogger.host("Unlock successful for client \(client.name)")

            // Send window list after successful unlock
            await sendWindowList(to: clientContext)

        case let .failure(code, errorMessage):
            response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: nil,
                error: UnlockError(code: code, message: errorMessage),
                canRetry: result.canRetry,
                retriesRemaining: retriesRemaining,
                retryAfterSeconds: retryAfter
            )
            MirageLogger.host("Unlock failed for client \(client.name): \(errorMessage)")
        }

        try? await clientContext.send(.unlockResponse, content: response)
    }
}

#endif
