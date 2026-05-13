//
//  WindowSpaceManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/6/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

/// Manages window placement ownership and restoration for Mirage streams.
/// Dedicated virtual-display streams can move windows between spaces; mirrored
/// app-window capture preserves the source display and only snapshots/ restores state.
actor WindowSpaceManager {
    // MARK: - Singleton

    static let shared = WindowSpaceManager()

    private init() {}

    // MARK: - State

    /// Saved window states keyed by window ID
    private var savedStates: [WindowID: SavedWindowState] = [:]

    private func prepareSavedStateIfNeeded(
        for windowID: WindowID,
        originalFrame: CGRect,
        owner: WindowBindingOwner?
    ) throws {
        if savedStates[windowID] == nil {
            let currentSpaces = CGSWindowSpaceBridge.spaces(for: windowID)
            let savedState = SavedWindowState(
                windowID: windowID,
                originalFrame: originalFrame,
                originalSpaceIDs: currentSpaces,
                owner: owner,
                savedAt: Date()
            )
            savedStates[windowID] = savedState
            MirageLogger.host(
                "Saving window \(windowID) state: frame=\(originalFrame), spaces=\(currentSpaces)"
            )
            return
        }

        if let owner,
           let existingOwner = savedStates[windowID]?.owner,
           existingOwner.streamID != owner.streamID {
            throw WindowSpaceError.ownerConflict(
                windowID,
                existingStreamID: existingOwner.streamID,
                requestedStreamID: owner.streamID
            )
        }

        if let owner,
           let existing = savedStates[windowID],
           existing.owner == nil {
            savedStates[windowID] = SavedWindowState(
                windowID: existing.windowID,
                originalFrame: existing.originalFrame,
                originalSpaceIDs: existing.originalSpaceIDs,
                owner: owner,
                savedAt: existing.savedAt
            )
        }

        MirageLogger.host(
            "Window \(windowID) already has saved state; preserving original state during move"
        )
    }

    // MARK: - Window Movement

    /// Move a window to a virtual display's space
    /// - Parameters:
    ///   - windowID: The window to move
    ///   - spaceID: The target space ID (from virtual display)
    ///   - displayID: The virtual display ID (for activating the display space)
    ///   - displayBounds: The bounds of the virtual display
    ///   - targetContentAspectRatio: Optional aspect ratio to fit inside display bounds for app streams.
    func moveWindow(
        _ windowID: WindowID,
        toSpaceID spaceID: CGSSpaceID,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        targetContentAspectRatio: CGFloat? = nil,
        owner: WindowBindingOwner? = nil
    )
    async throws {
        // Get current window info
        guard let windowInfo = windowInfo(for: windowID) else { throw WindowSpaceError.windowNotFound(windowID) }
        try prepareSavedStateIfNeeded(
            for: windowID,
            originalFrame: windowInfo.frame,
            owner: owner
        )

        let resolvedDisplayBounds = resolvePlacementDisplayBounds(
            displayID: displayID,
            fallbackBounds: displayBounds
        )
        let targetOrigin = resolvedDisplayBounds.origin
        let resolvedAXWindow = resolveAXWindow(for: windowID)
        let maxAttempts = 6

        var currentSpaceID = spaceID

        for attempt in 1 ... maxAttempts {
            // On retry, re-query the display's current space in case the virtual display
            // was reassigned to a new space by the window server.
            if attempt > 1 {
                let refreshedSpaceID = CGSWindowSpaceBridge.currentSpace(for: displayID)
                if refreshedSpaceID != 0, refreshedSpaceID != currentSpaceID {
                    MirageLogger.host(
                        "Display \(displayID) space changed from \(currentSpaceID) to \(refreshedSpaceID) on attempt \(attempt); adopting new space"
                    )
                    currentSpaceID = refreshedSpaceID
                }
            }

            // Apply a small position offset on retries to work around system-level
            // placement constraints that may silently reject the exact same coordinates.
            let retryOffset = CGFloat(attempt - 1) * 2
            let adjustedOrigin = CGPoint(
                x: targetOrigin.x + retryOffset,
                y: targetOrigin.y + retryOffset
            )

            let didActivateSpaceBeforeMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: currentSpaceID)
            if !didActivateSpaceBeforeMove {
                MirageLogger.host("Failed to set current space \(currentSpaceID) for display \(displayID) before move attempt \(attempt)")
            }

            CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: currentSpaceID)
            let didMoveWindow = CGSWindowSpaceBridge.moveWindow(windowID, to: adjustedOrigin)
            if !didMoveWindow {
                MirageLogger.debug(.host, "Failed to move window \(windowID) to position \(adjustedOrigin) on attempt \(attempt)")
            }
            if !raiseWindow(windowID, axWindow: resolvedAXWindow) {
                MirageLogger.debug(.host, "Failed to raise window \(windowID) on move attempt \(attempt)")
            }

            let didActivateSpaceAfterMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: currentSpaceID)
            if !didActivateSpaceAfterMove {
                MirageLogger.host("Failed to set current space \(currentSpaceID) for display \(displayID) after move attempt \(attempt)")
            }

            await fitWindowToVisibleFrame(
                windowID,
                visibleFrame: resolvedDisplayBounds,
                axWindow: resolvedAXWindow,
                targetContentAspectRatio: targetContentAspectRatio
            )

            // Snap back to the true target origin after fitting so verification uses
            // the canonical position regardless of the retry offset.
            if retryOffset > 0 {
                _ = CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin)
            }

            if verifyWindowPlacement(
                windowID,
                expectedSpaceID: currentSpaceID,
                displayBounds: resolvedDisplayBounds,
                targetOrigin: targetOrigin,
                axWindow: resolvedAXWindow,
                targetContentAspectRatio: targetContentAspectRatio
            ) {
                MirageLogger.host("Moved window \(windowID) to space \(currentSpaceID) at \(targetOrigin) (attempt \(attempt))")
                return
            }

            if attempt < maxAttempts {
                MirageLogger.host(
                    "Window \(windowID) placement not yet confirmed on attempt \(attempt)/\(maxAttempts); retrying"
                )
                do {
                    try await Task.sleep(for: .milliseconds(Int64(100 * attempt)))
                } catch {
                    return
                }
            }
        }

        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: currentSpaceID)
        centerWindow(windowID, on: resolvedDisplayBounds)
        do {
            try await Task.sleep(for: .milliseconds(40))
        } catch {
            return
        }

        if let fallbackFrame = resolvedWindowFrame(windowID, axWindow: resolvedAXWindow) {
            let expandedBounds = resolvedDisplayBounds.insetBy(dx: -24, dy: -24)
            if fallbackFrame.intersects(expandedBounds) {
                MirageLogger.host(
                    "Window \(windowID) placement fallback accepted centered frame \(fallbackFrame) in space \(currentSpaceID)"
                )
                return
            }
        }

        throw WindowSpaceError.moveFailed(
            windowID,
            "Placement verification failed for space \(currentSpaceID) on display \(displayID) (original space \(spaceID))"
        )
    }

    func prepareWindowForMirroredCapture(
        _ windowID: WindowID,
        owner: WindowBindingOwner? = nil
    )
    throws {
        guard let windowInfo = windowInfo(for: windowID) else {
            throw WindowSpaceError.windowNotFound(windowID)
        }
        try prepareSavedStateIfNeeded(
            for: windowID,
            originalFrame: windowInfo.frame,
            owner: owner
        )
    }

    /// Restore a window to its original position and space
    /// - Parameter windowID: The window to restore
    func restoreWindow(
        _ windowID: WindowID,
        expectedOwner: WindowBindingOwner? = nil
    ) async throws {
        guard let savedState = savedStates[windowID] else {
            MirageLogger.debug(.host, "No saved state for window \(windowID), cannot restore")
            throw WindowSpaceError.noOriginalState(windowID)
        }
        switch Self.validateRestoreOwner(expectedOwner: expectedOwner, savedOwner: savedState.owner) {
        case .allowed:
            break
        case let .ownerMismatch(expectedStreamID, actualStreamID):
            throw WindowSpaceError.ownerMismatch(
                windowID,
                expectedStreamID: expectedStreamID,
                actualStreamID: actualStreamID
            )
        }
        savedStates.removeValue(forKey: windowID)

        MirageLogger.host("Restoring window \(windowID) to original state")

        // Move back to original spaces
        if !savedState.originalSpaceIDs.isEmpty {
            for spaceID in savedState.originalSpaceIDs {
                CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            }
        }

        // Restore original position
        if let axWindow = resolveAXWindow(for: windowID) {
            _ = await resizeWindowViaAccessibility(
                windowID,
                to: savedState.originalFrame.size,
                axElement: axWindow
            )
        }
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: savedState.originalFrame.origin) {
            MirageLogger.debug(.host, "Failed to restore window \(windowID) position")
        }

        MirageLogger.host("Restored window \(windowID) to frame \(savedState.originalFrame)")
    }

    /// Restore a window without throwing (for cleanup scenarios)
    func restoreWindowSilently(
        _ windowID: WindowID,
        expectedOwner: WindowBindingOwner? = nil
    ) async {
        do {
            try await restoreWindow(windowID, expectedOwner: expectedOwner)
        } catch {
            MirageLogger.debug(.host, "Failed to restore window \(windowID): \(error)")
        }
    }

    // MARK: - Window Positioning

    /// Position a window within a display bounds
    /// - Parameters:
    ///   - windowID: The window to position
    ///   - position: Target position within display
    func positionWindow(_ windowID: WindowID, at position: CGPoint) {
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: position) { MirageLogger.debug(.host, "Failed to position window \(windowID) at \(position)") }
    }

    /// Center a window on a display
    /// - Parameters:
    ///   - windowID: The window to center
    ///   - displayBounds: The display bounds
    func centerWindow(_ windowID: WindowID, on displayBounds: CGRect) {
        guard let windowInfo = windowInfo(for: windowID) else { return }

        let windowSize = windowInfo.frame.size
        let centerX = displayBounds.origin.x + (displayBounds.width - windowSize.width) / 2
        let centerY = displayBounds.origin.y + (displayBounds.height - windowSize.height) / 2

        positionWindow(windowID, at: CGPoint(x: centerX, y: centerY))
    }

    // MARK: - State Queries

    func claimedWindowIDsForActiveOwners(activeStreamIDs: Set<StreamID>) -> Set<WindowID> {
        Self.claimedWindowIDsForActiveOwners(
            from: savedStates,
            activeStreamIDs: activeStreamIDs
        )
    }

    func restoreAllWindowsOwned(by streamID: StreamID) async {
        let windowIDs = Array(
            Self.windowIDsOwned(by: streamID, from: savedStates)
        )
        .sorted()

        guard !windowIDs.isEmpty else { return }

        MirageLogger.host(
            "Restoring \(windowIDs.count) saved window claim(s) for stopped stream \(streamID)"
        )

        for windowID in windowIDs {
            let expectedOwner = savedStates[windowID]?.owner
            do {
                try await restoreWindow(windowID, expectedOwner: expectedOwner)
            } catch {
                clearSavedState(for: windowID)
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                MirageLogger.host(
                    "owner_cleanup_cleared_saved_state window=\(windowID) ownerStreamID=\(streamID) error=\(renderedDetail)"
                )
            }
        }
    }

    // MARK: - Cleanup

    /// Clear saved state for a window without restoring
    /// Use when the window has been closed
    func clearSavedState(for windowID: WindowID) {
        savedStates.removeValue(forKey: windowID)
    }

    // MARK: - Helpers

    /// Returns compositor metadata for a window from `CGWindowList`.
    /// - Parameter windowID: Window identifier to query.
    func windowInfo(for windowID: WindowID) -> (frame: CGRect, title: String?, ownerPID: pid_t?)? {
        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]

        guard let info = windowList?.first else { return nil }

        guard let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }

        let frame = CGRect(x: x, y: y, width: width, height: height)
        let title = info[kCGWindowName] as? String
        let ownerPID = (info[kCGWindowOwnerPID] as? NSNumber).map { pid_t($0.int32Value) }

        return (frame, title, ownerPID)
    }
}

#endif
