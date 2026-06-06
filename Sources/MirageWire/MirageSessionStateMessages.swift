//
//  MirageSessionStateMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Host session-state control message definitions.
//

/// Host session availability projected into Mirage-owned wire payloads.
public enum MirageHostSessionAvailability: String, Sendable, Codable, Hashable {
    case ready
    case credentialsRequired
    case credentialsAndUserIdentifierRequired
    case unavailable

    /// Whether credentials are needed before the host can accept a Mirage session.
    public var requiresCredentials: Bool {
        switch self {
        case .ready:
            false
        case .credentialsRequired,
             .credentialsAndUserIdentifierRequired,
             .unavailable:
            true
        }
    }

    /// Whether the host also needs a user identifier with submitted credentials.
    public var requiresUserIdentifier: Bool {
        switch self {
        case .credentialsAndUserIdentifierRequired:
            true
        case .ready,
             .credentialsRequired,
             .unavailable:
            false
        }
    }

    /// Whether the host session is ready for normal streaming.
    public var isReady: Bool {
        self == .ready
    }
}

/// Host-to-client login-session availability update.
///
/// The host sends this immediately after connection and whenever the login session state changes.
package struct SessionStateUpdateMessage: Codable {
    /// Current host login-session availability.
    package let state: MirageHostSessionAvailability

    /// Session token associated with this state to prevent replayed unlock requests.
    package let sessionToken: String

    /// Whether the client must provide a user identifier for unlock.
    package let requiresUserIdentifier: Bool

    /// Creates a session-state update payload.
    package init(
        state: MirageHostSessionAvailability,
        sessionToken: String,
        requiresUserIdentifier: Bool
    ) {
        self.state = state
        self.sessionToken = sessionToken
        self.requiresUserIdentifier = requiresUserIdentifier
    }
}
