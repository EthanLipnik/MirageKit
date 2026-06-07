//
//  MirageErrorMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

// MARK: - Error Messages

/// Generic control-channel error payload.
package struct ErrorMessage: Codable {
    /// Machine-readable error code.
    package let code: ErrorCode

    /// User-facing or diagnostic error text.
    package let message: String

    /// Bundle identifier associated with an app-stream failure, when available.
    package let bundleIdentifier: String?

    /// Control-channel error categories exchanged between client and host.
    package enum ErrorCode: String, Codable {
        /// The sender could not classify the error more specifically.
        case unknown

        /// The peer sent a malformed or unsupported message.
        case invalidMessage

        /// A referenced stream does not exist.
        case streamNotFound

        /// A referenced window does not exist.
        case windowNotFound

        /// The host could not start an app-stream session.
        case appStreamStartupFailed

        /// The host failed while encoding media.
        case encodingError

        /// The client failed while decoding media.
        case decodingError

        /// Network transport failed.
        case networkError

        /// Authentication is required before the request can proceed.
        case authRequired

        /// The peer lacks permission for the requested operation.
        case permissionDenied

        /// The host could not create a virtual display.
        case virtualDisplayStartFailed

        /// The host could not resize a virtual display.
        case virtualDisplayResizeFailed

        /// The host login session is locked.
        case sessionLocked

        /// The host is waiting for local approval.
        case waitingForHostApproval
    }

    /// Creates a generic control-channel error payload.
    package init(
        code: ErrorCode,
        message: String,
        bundleIdentifier: String? = nil
    ) {
        self.code = code
        self.message = message
        self.bundleIdentifier = bundleIdentifier
    }
}

package extension ErrorMessage.ErrorCode {
    /// Maps a runtime-condition error into its wire error code.
    init(_ runtimeCondition: MirageCore.MirageRuntimeConditionError) {
        switch runtimeCondition {
        case .sessionLocked:
            self = .sessionLocked
        case .waitingForHostApproval:
            self = .waitingForHostApproval
        }
    }

    /// Converts a wire error code back into a runtime-condition error when possible.
    var runtimeConditionError: MirageCore.MirageRuntimeConditionError? {
        switch self {
        case .sessionLocked:
            .sessionLocked
        case .waitingForHostApproval:
            .waitingForHostApproval
        default:
            nil
        }
    }
}
