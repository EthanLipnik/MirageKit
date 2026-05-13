//
//  MessageTypes+AppWindowCloseAlerts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  App-window close-alert protocol message definitions.
//

import Foundation

/// Host-to-client alert shown when a streamed app window cannot close automatically.
public struct AppWindowCloseBlockedAlertMessage: Codable, Sendable, Equatable {
    /// User-selectable alert action.
    public struct Action: Codable, Sendable, Equatable {
        /// Stable action ID to send back to the host.
        public let id: String

        /// User-facing action title.
        public let title: String

        /// Whether the action is destructive.
        public let isDestructive: Bool

        /// Creates an alert action descriptor.
        package init(id: String, title: String, isDestructive: Bool = false) {
            self.id = id
            self.title = title
            self.isDestructive = isDestructive
        }
    }

    /// Bundle identifier for the app that presented the alert.
    public let bundleIdentifier: String

    /// Source app window that attempted to close.
    public let sourceWindowID: WindowID

    /// Stream that should present the alert UI.
    public let presentingStreamID: StreamID

    /// Host-issued token tying follow-up actions to this alert.
    public let alertToken: String

    /// Alert title.
    public let title: String?

    /// Alert body.
    public let message: String?

    /// Actions the client may ask the host to perform.
    public let actions: [Action]

    /// Creates a close-blocked alert payload.
    package init(
        bundleIdentifier: String,
        sourceWindowID: WindowID,
        presentingStreamID: StreamID,
        alertToken: String,
        title: String?,
        message: String?,
        actions: [Action]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.sourceWindowID = sourceWindowID
        self.presentingStreamID = presentingStreamID
        self.alertToken = alertToken
        self.title = title
        self.message = message
        self.actions = actions
    }
}

/// Client-to-host request to perform an action from a close-blocked alert.
package struct AppWindowCloseAlertActionRequestMessage: Codable {
    /// Host-issued alert token.
    package let alertToken: String

    /// Action ID selected by the user.
    package let actionID: String

    /// Stream currently presenting the alert.
    package let presentingStreamID: StreamID

    /// Creates a close-alert action request.
    package init(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID
    ) {
        self.alertToken = alertToken
        self.actionID = actionID
        self.presentingStreamID = presentingStreamID
    }
}

/// Host-to-client result for a close-alert action request.
public struct AppWindowCloseAlertActionResultMessage: Codable, Sendable, Equatable {
    /// Host-issued alert token.
    public let alertToken: String

    /// Action ID that was attempted.
    public let actionID: String

    /// Whether the action succeeded.
    public let success: Bool

    /// Failure reason when `success` is false.
    public let reason: String?

    /// Creates a close-alert action result payload.
    package init(
        alertToken: String,
        actionID: String,
        success: Bool,
        reason: String?
    ) {
        self.alertToken = alertToken
        self.actionID = actionID
        self.success = success
        self.reason = reason
    }
}
