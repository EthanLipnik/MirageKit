//
//  MessageTypes+LoginDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import CoreGraphics
import Foundation

// MARK: - Login Display Streaming

/// Sent when host starts streaming the login/lock screen to client
/// Client should prepare to receive frames marked with .loginDisplay flag
package struct LoginDisplayReadyMessage: Codable {
    /// Stream ID for the login display stream
    package let streamID: UInt32
    /// Resolution of the login display
    package let width: Int
    package let height: Int
    /// Current session state (screenLocked, loginScreen, etc.)
    package let sessionState: HostSessionState
    /// Whether username is needed (true for loginScreen, false for screenLocked)
    package let requiresUsername: Bool
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    package var dimensionToken: UInt16?

    package init(
        streamID: UInt32,
        width: Int,
        height: Int,
        sessionState: HostSessionState,
        requiresUsername: Bool,
        dimensionToken: UInt16? = nil
    ) {
        self.streamID = streamID
        self.width = width
        self.height = height
        self.sessionState = sessionState
        self.requiresUsername = requiresUsername
        self.dimensionToken = dimensionToken
    }
}

/// Sent when login display stream stops (user logged in successfully)
/// Client should transition to normal window selection mode
package struct LoginDisplayStoppedMessage: Codable {
    /// The stream ID that was stopped
    package let streamID: UInt32
    /// New session state (should be .active)
    package let newState: HostSessionState

    package init(streamID: UInt32, newState: HostSessionState) {
        self.streamID = streamID
        self.newState = newState
    }
}
