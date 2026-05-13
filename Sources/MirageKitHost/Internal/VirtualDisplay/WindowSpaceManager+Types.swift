//
//  WindowSpaceManager+Types.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
extension WindowSpaceManager {
    /// Stream that currently owns a temporary window-space binding.
    struct WindowBindingOwner {
        let streamID: StreamID
    }

    /// Saved state used to restore a window after Mirage moves or claims it.
    struct SavedWindowState {
        let windowID: WindowID
        let originalFrame: CGRect
        let originalSpaceIDs: [CGSSpaceID]
        let owner: WindowBindingOwner?
        let savedAt: Date
    }

    /// Errors produced by window movement, ownership, and restoration operations.
    enum WindowSpaceError: Error, LocalizedError {
        case windowNotFound(WindowID)
        case noOriginalState(WindowID)
        case moveFailed(WindowID, String)
        case ownerConflict(WindowID, existingStreamID: StreamID, requestedStreamID: StreamID)
        case ownerMismatch(WindowID, expectedStreamID: StreamID, actualStreamID: StreamID)

        var errorDescription: String? {
            switch self {
            case let .windowNotFound(id):
                "Window \(id) not found"
            case let .noOriginalState(id):
                "No saved state for window \(id)"
            case let .moveFailed(id, reason):
                "Failed to move window \(id): \(reason)"
            case let .ownerConflict(id, existingStreamID, requestedStreamID):
                "Window \(id) already owned by stream \(existingStreamID); requested stream \(requestedStreamID)"
            case let .ownerMismatch(id, expectedStreamID, actualStreamID):
                "Window \(id) restore owner mismatch expected stream \(expectedStreamID), actual stream \(actualStreamID)"
            }
        }
    }

    /// Result of validating whether a saved window claim may be restored by a caller.
    enum RestoreOwnerValidationResult: Equatable {
        case allowed
        case ownerMismatch(expectedStreamID: StreamID, actualStreamID: StreamID)
    }
}
#endif
