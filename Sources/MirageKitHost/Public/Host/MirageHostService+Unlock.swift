//
//  MirageHostService+Unlock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import MirageBootstrapShared
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
        MirageInstrumentation.record(.hostUnlockRequested)

        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            MirageLogger.error(.host, "No client context for unlock request")
            return
        }

        // Check if remote unlock is enabled
        guard remoteUnlockEnabled else {
            MirageInstrumentation.record(.hostUnlockRejected(.remoteUnlockDisabled))
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
            MirageInstrumentation.record(.hostUnlockRejected(.notAuthorized))
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
            MirageLogger.error(.host, error: error, message: "Failed to decode unlock request: ")
            MirageInstrumentation.record(.hostUnlockRejected(.invalidRequestFormat))
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
            MirageInstrumentation.record(.hostUnlockRejected(.sessionTokenExpired))
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
            requiresUserIdentifier: sessionState.requiresUserIdentifier,
            clientID: client.id
        )

        // Build response based on result
        let response: UnlockResponseMessage
        switch result {
        case .success:
            MirageInstrumentation.record(.hostUnlockSucceeded)
            response = UnlockResponseMessage(
                success: true,
                newState: .ready,
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
            let mappedCode = mapUnlockErrorCode(code)
            MirageInstrumentation.record(.hostUnlockFailed(.init(name: mappedCode.rawValue)))
            response = UnlockResponseMessage(
                success: false,
                newState: sessionState,
                newSessionToken: nil,
                error: UnlockError(code: mappedCode, message: errorMessage),
                canRetry: result.canRetry,
                retriesRemaining: retriesRemaining,
                retryAfterSeconds: retryAfter
            )
            MirageLogger.host("Unlock failed for client \(client.name): \(errorMessage)")
        }

        try? await clientContext.send(.unlockResponse, content: response)
    }

    private func mapUnlockErrorCode(_ code: LoomCredentialSubmissionErrorCode) -> UnlockErrorCode {
        switch code {
        case .invalidCredentials:
            .invalidCredentials
        case .rateLimited:
            .rateLimited
        case .sessionExpired:
            .sessionExpired
        case .notReady:
            .notLocked
        case .notSupported:
            .notSupported
        case .notAuthorized:
            .notAuthorized
        case .timeout:
            .timeout
        case .internalError:
            .internalError
        }
    }
}

#endif
