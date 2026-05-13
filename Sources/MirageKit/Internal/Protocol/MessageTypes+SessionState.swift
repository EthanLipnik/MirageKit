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

/// Host-to-client login-session availability update.
///
/// The host sends this immediately after connection and whenever the login session state changes.
package struct SessionStateUpdateMessage: Codable {
    /// Current host login-session availability.
    package let state: LoomSessionAvailability

    /// Session token associated with this state to prevent replayed unlock requests.
    package let sessionToken: String

    /// Whether the client must provide a user identifier for unlock.
    package let requiresUserIdentifier: Bool

    /// Creates a session-state update payload.
    package init(
        state: LoomSessionAvailability,
        sessionToken: String,
        requiresUserIdentifier: Bool
    ) {
        self.state = state
        self.sessionToken = sessionToken
        self.requiresUserIdentifier = requiresUserIdentifier
    }
}
