//
//  AppStreamStartupFailureClassifier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Shared classification for app-window startup failures.
//


import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
enum AppStreamStartupFailureClassifier {
    static func isRetryableWindowStartupError(_ error: Error) -> Bool {
        if isNonRetryableVirtualDisplayAllocationError(error) { return false }

        if let windowStartError = error as? WindowStreamStartError {
            switch windowStartError {
            case .windowAlreadyBound, .windowStartupInProgress:
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
            case .creationFailed, .retinaCollapsedToOneX, .apiNotAvailable:
                return false
            case .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound:
                return true
            }
        }

        if let mirageError = error as? MirageCore.MirageError {
            switch mirageError {
            case .windowNotFound, .timeout:
                return true
            case .alreadyAdvertising,
                 .notAdvertising,
                 .connectionFailed,
                 .connectionRejected,
                 .authenticationFailed,
                 .streamNotFound,
                 .encodingError,
                 .decodingError,
                 .permissionDenied,
                 .protocolError,
                 .captureSetupFailed:
                return false
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
            case .creationFailed, .retinaCollapsedToOneX, .apiNotAvailable:
                return true
            case .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound:
                return false
            }
        }

        return false
    }
}
#endif
