//
//  MessageTypes+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import CoreGraphics
import Foundation

// MARK: - Input Messages

package struct InputEventMessage: Codable {
    package let streamID: StreamID
    package let event: MirageInputEvent

    package init(streamID: StreamID, event: MirageInputEvent) {
        self.streamID = streamID
        self.event = event
    }
}
