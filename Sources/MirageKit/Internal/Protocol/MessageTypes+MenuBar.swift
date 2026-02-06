//
//  MessageTypes+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Menu Bar Passthrough Messages

/// Menu bar structure update (Host → Client)
/// Sent when the remote app's menu bar changes or on initial stream start
package struct MenuBarUpdateMessage: Codable {
    /// The stream this menu bar applies to
    package let streamID: StreamID
    /// The menu bar structure, or nil if extraction failed/unavailable
    package let menuBar: MirageMenuBar?
    /// Error message if extraction failed
    package let errorMessage: String?

    package init(streamID: StreamID, menuBar: MirageMenuBar?, errorMessage: String? = nil) {
        self.streamID = streamID
        self.menuBar = menuBar
        self.errorMessage = errorMessage
    }
}

/// Request to execute a menu action (Client → Host)
package struct MenuActionRequestMessage: Codable {
    /// The stream to execute the action on
    package let streamID: StreamID
    /// Path to the menu item: [menuIndex, itemIndex, submenuItemIndex, ...]
    package let actionPath: [Int]

    package init(streamID: StreamID, actionPath: [Int]) {
        self.streamID = streamID
        self.actionPath = actionPath
    }
}

/// Result of menu action execution (Host → Client)
package struct MenuActionResultMessage: Codable {
    /// The stream the action was executed on
    package let streamID: StreamID
    /// Whether the action was successful
    package let success: Bool
    /// Error message if failed
    package let errorMessage: String?

    package init(streamID: StreamID, success: Bool, errorMessage: String? = nil) {
        self.streamID = streamID
        self.success = success
        self.errorMessage = errorMessage
    }
}
