//
//  AppStreamStartupFailureClassifier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Shared classification for app-window startup failures.
//

import MirageKit

#if os(macOS)
enum AppStreamStartupFailureClassifier {
    static func isRetryableWindowStartupError(_ error: Error) -> Bool {
        if isNonRetryableVirtualDisplayAllocationError(error) { return false }

        if let windowStartError = error as? WindowStreamStartError {
            switch windowStartError {
            case .windowAlreadyBound:
                return false
            case let .virtualDisplayStartFailed(code, _):
                if code.isOwnershipConflict { return false }
                return true
            }
        }

        if let windowSpaceError = error as? WindowSpaceManager.WindowSpaceError {
            switch windowSpaceError {
            case .moveFailed, .windowNotFound:
                return true
            case .noOriginalState, .ownerConflict, .ownerMismatch:
                return false
            }
        }

        if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
            switch sharedDisplayError {
            case .creationFailed, .apiNotAvailable:
                return false
            case .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .scDisplayNotFound:
                return true
            }
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case .windowNotFound, .timeout:
                return true
            case .alreadyAdvertising,
                 .notAdvertising,
                 .connectionFailed,
                 .authenticationFailed,
                 .streamNotFound,
                 .encodingError,
                 .decodingError,
                 .permissionDenied,
                 .protocolError:
                return false
            }
        }

        return false
    }

    static func shouldHideFailedWindowInInventory(_ error: Error) -> Bool {
        isNonRetryableVirtualDisplayAllocationError(error)
    }

    static func isExpectedWindowStartupRaceError(_ error: Error) -> Bool {
        if let mirageError = error as? MirageError {
            switch mirageError {
            case .streamNotFound, .windowNotFound:
                return true
            default:
                break
            }
        }

        if let windowSpaceError = error as? WindowSpaceManager.WindowSpaceError {
            if case .windowNotFound = windowSpaceError {
                return true
            }
        }

        return false
    }

    static func isNonRetryableVirtualDisplayAllocationError(_ error: Error) -> Bool {
        if let windowStartError = error as? WindowStreamStartError {
            if case let .virtualDisplayStartFailed(code, _) = windowStartError {
                return code.isNonRetryableVirtualDisplayAllocationFailure
            }
        }

        if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
            switch sharedDisplayError {
            case .creationFailed, .apiNotAvailable:
                return true
            case .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .scDisplayNotFound:
                return false
            }
        }

        return false
    }
}
#endif
