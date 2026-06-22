//
//  ControlMessageTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageWire
@testable import MirageKit

private enum ControlMessageTestParseError: Error {
    case needMoreData
    case invalidFrame(String)
}

/// Parses a complete control message for serialization tests that do not exercise streaming receive buffers.
func requireParsedControlMessage(from data: Data, offset: Int = 0) throws -> (MirageWire.ControlMessage, Int) {
    switch MirageWire.ControlMessage.deserialize(from: data, offset: offset) {
    case let .success(message, bytesConsumed):
        return (message, bytesConsumed)
    case .needMoreData:
        throw ControlMessageTestParseError.needMoreData
    case let .invalidFrame(reason):
        throw ControlMessageTestParseError.invalidFrame(reason)
    }
}
