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
            case let .virtualDisplayStartFailed(details):
                if isNonRetryableOwnerConflictDescription(details.lowercased()) {
                    return false
                }
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

        let normalizedDescription = error.localizedDescription.lowercased()
        if isNonRetryableOwnerConflictDescription(normalizedDescription) {
            return false
        }
        if normalizedDescription.contains("window not found") ||
            normalizedDescription.contains("disappeared before stream startup") ||
            normalizedDescription.contains("virtual-display stream start failed") ||
            normalizedDescription.contains("dedicated virtual display start failed") {
            return true
        }

        return false
    }

    static func shouldHideFailedWindowInInventory(_ error: Error) -> Bool {
        isNonRetryableVirtualDisplayAllocationError(error)
    }

    static func isNonRetryableVirtualDisplayAllocationError(_ error: Error) -> Bool {
        if let windowStartError = error as? WindowStreamStartError {
            if case let .virtualDisplayStartFailed(details) = windowStartError {
                if isNonRetryableVirtualDisplayAllocationDescription(details.lowercased()) {
                    return true
                }
            }
        }

        return isNonRetryableVirtualDisplayAllocationDescription(error.localizedDescription.lowercased())
    }

    private static func isNonRetryableVirtualDisplayAllocationDescription(_ description: String) -> Bool {
        description.contains("failed to create virtual display") ||
            description.contains("virtual display failed activation") ||
            description.contains("spawnproxy message error") ||
            description.contains("pluginwithoptions")
    }

    private static func isNonRetryableOwnerConflictDescription(_ description: String) -> Bool {
        description.contains("already owned by stream") ||
            description.contains("restore owner mismatch") ||
            description.contains("owner conflict") ||
            description.contains("owner mismatch")
    }
}
#endif
