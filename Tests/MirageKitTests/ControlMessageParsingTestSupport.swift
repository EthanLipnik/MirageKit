//
//  ControlMessageParsingTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Shared helpers for asserting complete control-frame parsing in tests.
//

@testable import MirageKit
import Foundation

private enum ControlMessageParseTestError: Error {
    case needMoreData
    case invalidFrame(String)
}

func requireParsedControlMessage(from data: Data, offset: Int = 0) throws -> (ControlMessage, Int) {
    switch ControlMessage.deserialize(from: data, offset: offset) {
    case let .success(message, bytesConsumed):
        return (message, bytesConsumed)
    case .needMoreData:
        throw ControlMessageParseTestError.needMoreData
    case let .invalidFrame(reason):
        throw ControlMessageParseTestError.invalidFrame(reason)
    }
}
