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

    package func serializePayload() throws -> Data {
        try InputEventBinaryCodec.serialize(self)
    }

    package static func deserializePayload(_ payload: Data) throws -> InputEventMessage {
        guard let firstByte = payload.first else {
            throw MirageError.protocolError("Input payload is empty")
        }
        if firstByte == InputEventBinaryCodec.formatVersion {
            return try InputEventBinaryCodec.deserialize(payload)
        }
        return try JSONDecoder().decode(InputEventMessage.self, from: payload)
    }
}
