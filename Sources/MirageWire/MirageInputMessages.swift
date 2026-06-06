//
//  MirageInputMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageInput

// MARK: - Input Messages

package struct InputEventMessage: Codable {
    package let streamID: StreamID
    package let event: MirageInput.MirageInputEvent

    package init(streamID: StreamID, event: MirageInput.MirageInputEvent) {
        self.streamID = streamID
        self.event = event
    }

    package func serializePayload() throws -> Data {
        try InputEventBinaryCodec.serialize(self)
    }

    package static func deserializePayload(_ payload: Data) throws -> InputEventMessage {
        try InputEventBinaryCodec.deserialize(payload)
    }
}
