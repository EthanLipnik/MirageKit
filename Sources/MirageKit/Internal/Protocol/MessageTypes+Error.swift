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
    package let bundleIdentifier: String?

    package enum ErrorCode: String, Codable {
        case unknown
        case invalidMessage
        case streamNotFound
        case windowNotFound
        case appStreamStartupFailed
        case encodingError
        case decodingError
        case networkError
        case authRequired
        case permissionDenied
        case virtualDisplayStartFailed
        case virtualDisplayResizeFailed
        case sessionLocked
        case waitingForHostApproval
    }

    package init(
        code: ErrorCode,
        message: String,
        streamID: StreamID? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.code = code
        self.message = message
        self.streamID = streamID
        self.bundleIdentifier = bundleIdentifier
    }
}

package extension ErrorMessage.ErrorCode {
    init(_ runtimeCondition: MirageRuntimeConditionError) {
        switch runtimeCondition {
        case .sessionLocked:
            self = .sessionLocked
        case .waitingForHostApproval:
            self = .waitingForHostApproval
        }
    }

    var runtimeConditionError: MirageRuntimeConditionError? {
        switch self {
        case .sessionLocked:
            return .sessionLocked
        case .waitingForHostApproval:
            return .waitingForHostApproval
        default:
            return nil
        }
    }
}
