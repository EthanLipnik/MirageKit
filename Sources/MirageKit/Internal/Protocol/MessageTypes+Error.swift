//
//  MessageTypes+Error.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Error Messages

package struct ErrorMessage: Codable {
    package let code: ErrorCode
    package let message: String
    package let streamID: StreamID?

    package enum ErrorCode: String, Codable {
        case unknown
        case invalidMessage
        case streamNotFound
        case windowNotFound
        case encodingError
        case decodingError
        case networkError
        case authRequired
        case permissionDenied
    }

    package init(code: ErrorCode, message: String, streamID: StreamID? = nil) {
        self.code = code
        self.message = message
        self.streamID = streamID
    }
}
