//
//  MirageMenuBarMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

// MARK: - Menu Bar Passthrough Messages

/// Host-to-client menu bar structure update for a streamed app window.
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
