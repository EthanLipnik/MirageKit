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
