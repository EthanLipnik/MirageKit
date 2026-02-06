//
//  MessageTypes+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Session State Messages (Headless Mac Support)

/// Host session state - indicates whether the Mac is accessible for streaming
public enum HostSessionState: String, Codable, Sendable {
    /// Screen is unlocked, ready for normal streaming
    case active
    /// Screen is locked (user logged in but screen locked, password only needed)
    case screenLocked
    /// At login window (no user session, username + password needed)
    case loginScreen
    /// Mac is asleep (needs wake before unlock)
    case sleeping

    /// Whether credentials are required to reach active state
    public var requiresUnlock: Bool {
        switch self {
        case .active: false
        case .loginScreen,
             .screenLocked,
             .sleeping: true
        }
    }

    /// Whether username is needed in addition to password
    public var requiresUsername: Bool {
        switch self {
        case .loginScreen: true
        case .active,
             .screenLocked,
             .sleeping: false
        }
    }
}

/// Session state update sent from host to client
/// Sent immediately after connection and whenever state changes
package struct SessionStateUpdateMessage: Codable {
    /// Current session state
    package let state: HostSessionState
    /// Session token for this state (prevents replay attacks)
    package let sessionToken: String
    /// Whether username is needed for unlock
    package let requiresUsername: Bool
    /// Timestamp of this update
    package let timestamp: Date

    package init(
        state: HostSessionState,
        sessionToken: String,
        requiresUsername: Bool,
        timestamp: Date
    ) {
        self.state = state
        self.sessionToken = sessionToken
        self.requiresUsername = requiresUsername
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
    package let newState: HostSessionState
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
        newState: HostSessionState,
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
