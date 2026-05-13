//
//  WindowStreamStartErrors.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)

enum WindowStreamStartFailureCode: Int, Equatable, Hashable, Comparable {
    case unknown = 0
    case virtualDisplayCreationFailed = 1
    case virtualDisplayUnavailable = 2
    case windowPlacementFailed = 3
    case windowOwnerConflict = 4
    case windowOwnerMismatch = 5
    case windowAlreadyBound = 6
    case windowNotFound = 7
    case noSavedWindowState = 8
    case operationTimedOut = 9
    case runtimeConditionBlocked = 10

    static func < (lhs: WindowStreamStartFailureCode, rhs: WindowStreamStartFailureCode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isOwnershipConflict: Bool {
        self == .windowOwnerConflict || self == .windowOwnerMismatch || self == .windowAlreadyBound
    }

    var isNonRetryableVirtualDisplayAllocationFailure: Bool {
        self == .virtualDisplayCreationFailed || self == .virtualDisplayUnavailable
    }
}

enum WindowStreamStartError: Error {
    case virtualDisplayStartFailed(code: WindowStreamStartFailureCode, details: String)
    case windowAlreadyBound(windowID: WindowID, existingStreamID: StreamID)
    case windowStartupInProgress(windowID: WindowID)
}

extension WindowStreamStartError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .virtualDisplayStartFailed(_, details):
            "Dedicated virtual display start failed: \(details)"
        case let .windowAlreadyBound(windowID, existingStreamID):
            "Window \(windowID) is already streamed by stream \(existingStreamID)"
        case let .windowStartupInProgress(windowID):
            "Window \(windowID) is already reserved by another startup attempt"
        }
    }
}

func windowStreamStartFailureCode(for error: Error) -> WindowStreamStartFailureCode {
    if let windowStartError = error as? WindowStreamStartError {
        switch windowStartError {
        case let .virtualDisplayStartFailed(code, _):
            return code
        case .windowAlreadyBound, .windowStartupInProgress:
            return .windowAlreadyBound
        }
    }

    if let windowSpaceError = error as? WindowSpaceManager.WindowSpaceError {
        switch windowSpaceError {
        case .moveFailed:
            return .windowPlacementFailed
        case .ownerConflict:
            return .windowOwnerConflict
        case .ownerMismatch:
            return .windowOwnerMismatch
        case .windowNotFound:
            return .windowNotFound
        case .noOriginalState:
            return .noSavedWindowState
        }
    }

    if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
        switch sharedDisplayError {
        case .creationFailed:
            return .virtualDisplayCreationFailed
        case .apiNotAvailable, .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound:
            return .virtualDisplayUnavailable
        }
    }

    if let nsError = error as NSError?,
       nsError.domain == "CoreGraphicsErrorDomain",
       nsError.code == 1003 {
        return .windowPlacementFailed
    }

    if error is MirageRuntimeConditionError {
        return .runtimeConditionBlocked
    }

    if let mirageError = error as? MirageError {
        switch mirageError {
        case .windowNotFound:
            return .windowNotFound
        case .timeout:
            return .operationTimedOut
        case let .protocolError(message):
            if message.contains("Unable to resolve SCWindow") || message.contains("Unable to resolve SCDisplay") {
                return .windowNotFound
            }
            return .unknown
        default:
            return .unknown
        }
    }

    return .unknown
}

#endif
