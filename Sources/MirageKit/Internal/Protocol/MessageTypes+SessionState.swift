//
//  MessageTypes+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation
import Loom

// MARK: - Session State Messages (Headless Mac Support)

/// Session state update sent from host to client
/// Sent immediately after connection and whenever state changes
package struct SessionStateUpdateMessage: Codable {
    /// Current session state
    package let state: LoomSessionAvailability
    /// Session token for this state (prevents replay attacks)
    package let sessionToken: String
    /// Whether username is needed for unlock
    package let requiresUserIdentifier: Bool
    /// Timestamp of this update
    package let timestamp: Date

    package init(
        state: LoomSessionAvailability,
        sessionToken: String,
        requiresUserIdentifier: Bool,
        timestamp: Date
    ) {
        self.state = state
        self.sessionToken = sessionToken
        self.requiresUserIdentifier = requiresUserIdentifier
        self.timestamp = timestamp
    }
}

/// Unlock request sent from client to host
package struct UnlockRequestMessage: Codable {
    /// Session token from SessionStateUpdateMessage (must match current)
    package let sessionToken: String
    /// Username (required for loginScreen state, ignored otherwise)
    package let username: String?
    /// Password for unlock
    package let password: String

    package init(sessionToken: String, username: String?, password: String) {
        self.sessionToken = sessionToken
        self.username = username
        self.password = password
    }
}

/// Unlock response sent from host to client
package struct UnlockResponseMessage: Codable {
    /// Whether unlock was successful
    package let success: Bool
    /// New session state after attempt
    package let newState: LoomSessionAvailability
    /// New session token (if state changed)
    package let newSessionToken: String?
    /// Error details if failed
    package let error: UnlockError?
    /// Whether client can retry with same token
    package let canRetry: Bool
    /// Number of attempts remaining before lockout
    package let retriesRemaining: Int?
    /// Seconds to wait before next attempt (rate limiting)
    package let retryAfterSeconds: Int?

    package init(
        success: Bool,
        newState: LoomSessionAvailability,
        newSessionToken: String?,
        error: UnlockError?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    ) {
        self.success = success
        self.newState = newState
        self.newSessionToken = newSessionToken
        self.error = error
        self.canRetry = canRetry
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Unlock error details
package struct UnlockError: Codable {
    package let code: UnlockErrorCode
    package let message: String

    package init(code: UnlockErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Error codes for unlock failures
package enum UnlockErrorCode: String, Codable {
    /// Wrong username or password
    case invalidCredentials
    /// Too many failed attempts
    case rateLimited
    /// Session token expired or invalid
    case sessionExpired
    /// Host is not in a locked state
    case notLocked
    /// Remote unlock is disabled on host
    case notSupported
    /// Client not authorized for unlock
    case notAuthorized
    /// Unlock operation timed out
    case timeout
    /// Internal error on host
    case internalError
}
