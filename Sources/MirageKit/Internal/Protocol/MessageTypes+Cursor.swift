//
//  MessageTypes+Cursor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Cursor Messages

/// Cursor state update sent from host to client when cursor appearance changes
package struct CursorUpdateMessage: Codable {
    /// The stream this cursor update applies to
    package let streamID: StreamID
    /// The current cursor type on the host
    package let cursorType: MirageCursorType
    /// Whether the cursor is currently within the streamed window bounds
    package let isVisible: Bool

    package init(streamID: StreamID, cursorType: MirageCursorType, isVisible: Bool) {
        self.streamID = streamID
        self.cursorType = cursorType
        self.isVisible = isVisible
    }
}

/// Cursor position update sent from host to client for secondary display sync
package struct CursorPositionUpdateMessage: Codable {
    /// The stream this cursor position applies to
    package let streamID: StreamID
    /// Normalized cursor position (0-1, top-left origin)
    package let normalizedX: Float
    package let normalizedY: Float
    /// Whether the cursor is currently within the streamed window bounds
    package let isVisible: Bool

    package init(streamID: StreamID, normalizedX: Float, normalizedY: Float, isVisible: Bool) {
        self.streamID = streamID
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.isVisible = isVisible
    }
}
