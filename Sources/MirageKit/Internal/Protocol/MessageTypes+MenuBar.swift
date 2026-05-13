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

/// Host-to-client menu bar structure update for a streamed app window.
///
/// The host sends this when the remote app's menu bar changes and on initial stream start.
package struct MenuBarUpdateMessage: Codable {
    /// Stream this menu bar applies to.
    package let streamID: StreamID

    /// Menu bar structure, or `nil` if extraction failed or is unavailable.
    package let menuBar: MirageMenuBar?

    /// Creates a menu bar update payload.
    package init(streamID: StreamID, menuBar: MirageMenuBar?) {
        self.streamID = streamID
        self.menuBar = menuBar
    }
}

/// Client-to-host request to execute a menu action.
package struct MenuActionRequestMessage: Codable {
    /// Stream to execute the action on.
    package let streamID: StreamID

    /// Path to the menu item, such as `[menuIndex, itemIndex, submenuItemIndex]`.
    package let actionPath: [Int]

    /// Creates a menu action request.
    package init(streamID: StreamID, actionPath: [Int]) {
        self.streamID = streamID
        self.actionPath = actionPath
    }
}
