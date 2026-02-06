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
import AppKit

/// Manages window movement between displays/spaces for Mirage streams
/// Handles moving windows to virtual displays and restoring them on stream end
actor WindowSpaceManager {
    // MARK: - Singleton

    static let shared = WindowSpaceManager()

    private init() {}

    // MARK: - Types

    /// Saved state for restoring a window to its original position
    struct SavedWindowState: Sendable {
        let windowID: WindowID
        let originalFrame: CGRect
        let originalSpaceIDs: [CGSSpaceID]
        let savedAt: Date
    }

    /// Error types for window operations
    enum WindowSpaceError: Error, LocalizedError {
        case windowNotFound(WindowID)
        case noOriginalState(WindowID)
        case moveFailed(WindowID, String)

        var errorDescription: String? {
            switch self {
            case let .windowNotFound(id):
                "Window \(id) not found"
            case let .noOriginalState(id):
                "No saved state for window \(id)"
            case let .moveFailed(id, reason):
                "Failed to move window \(id): \(reason)"
            }
        }
    }

    // MARK: - State

    /// Saved window states keyed by window ID
    private var savedStates: [WindowID: SavedWindowState] = [:]

    // MARK: - Window Movement

    /// Move a window to a virtual display's space
    /// - Parameters:
    ///   - windowID: The window to move
    ///   - spaceID: The target space ID (from virtual display)
    ///   - displayID: The virtual display ID (for activating the display space)
    ///   - displayBounds: The bounds of the virtual display
    func moveWindow(
        _ windowID: WindowID,
        toSpaceID spaceID: CGSSpaceID,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    )
    async throws {
        // Get current window info
        guard let windowInfo = getWindowInfo(windowID) else { throw WindowSpaceError.windowNotFound(windowID) }

        if savedStates[windowID] == nil {
            let currentSpaces = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
            let savedState = SavedWindowState(
                windowID: windowID,
                originalFrame: windowInfo.frame,
                originalSpaceIDs: currentSpaces,
                savedAt: Date()
            )
            savedStates[windowID] = savedState
            MirageLogger.host("Saving window \(windowID) state: frame=\(windowInfo.frame), spaces=\(currentSpaces)")
        } else {
            MirageLogger.host("Window \(windowID) already has saved state; preserving original state during move")
        }

        // Move window to the virtual display's space
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        let didActivateSpace = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
        if !didActivateSpace { MirageLogger.host("Failed to set current space \(spaceID) for display \(displayID)") }

        // Position window at the origin of the virtual display
        // The window will fill the display as needed
        let targetOrigin = displayBounds.origin
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin) { MirageLogger.debug(.host, "Failed to move window \(windowID) to position \(targetOrigin)") }

        MirageLogger.host("Moved window \(windowID) to space \(spaceID) at \(targetOrigin)")
    }

    /// Restore a window to its original position and space
    /// - Parameter windowID: The window to restore
    func restoreWindow(_ windowID: WindowID) async throws {
        guard let savedState = savedStates.removeValue(forKey: windowID) else {
            MirageLogger.debug(.host, "No saved state for window \(windowID), cannot restore")
            throw WindowSpaceError.noOriginalState(windowID)
        }

        MirageLogger.host("Restoring window \(windowID) to original state")

        // Move back to original spaces
        if !savedState.originalSpaceIDs.isEmpty {
            for spaceID in savedState.originalSpaceIDs {
                CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            }
        }

        // Restore original position
        if !CGSWindowSpaceBridge.moveWindow(windowID, to: savedState.originalFrame.origin) { MirageLogger.debug(.host, "Failed to restore window \(windowID) position") }

        MirageLogger.host("Restored window \(windowID) to frame \(savedState.originalFrame)")
    }

    /// Restore a window without throwing (for cleanup scenarios)
    func restoreWindowSilently(_ windowID: WindowID) async {
        do {
            try await restoreWindow(windowID)
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
        guard let windowInfo = getWindowInfo(windowID) else { return }

        let windowSize = windowInfo.frame.size
        let centerX = displayBounds.origin.x + (displayBounds.width - windowSize.width) / 2
        let centerY = displayBounds.origin.y + (displayBounds.height - windowSize.height) / 2

        positionWindow(windowID, at: CGPoint(x: centerX, y: centerY))
    }

    // MARK: - State Queries

    /// Check if we have saved state for a window
    func hasSavedState(for windowID: WindowID) -> Bool {
        savedStates[windowID] != nil
    }

    /// Get the saved state for a window
    func getSavedState(for windowID: WindowID) -> SavedWindowState? {
        savedStates[windowID]
    }

    /// Get all windows with saved states
    func windowsWithSavedStates() -> [WindowID] {
        Array(savedStates.keys)
    }

    /// Get all window IDs that have been moved to the shared virtual display
    /// Alias for windowsWithSavedStates() with clearer semantics for shared display usage
    func getMovedWindowIDs() -> [WindowID] {
        Array(savedStates.keys)
    }

    // MARK: - Cleanup

    /// Clear saved state for a window without restoring
    /// Use when the window has been closed
    func clearSavedState(for windowID: WindowID) {
        savedStates.removeValue(forKey: windowID)
    }

    /// Restore all windows and clear all saved states
    /// Called during host shutdown
    func restoreAllWindows() async {
        let windowIDs = Array(savedStates.keys)
        for windowID in windowIDs {
            await restoreWindowSilently(windowID)
        }
        MirageLogger.host("Restored all \(windowIDs.count) windows")
    }

    // MARK: - Helpers

    /// Get information about a window from CGWindowList
    private func getWindowInfo(_ windowID: WindowID) -> (frame: CGRect, title: String?)? {
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

        return (frame, title)
    }

    /// Get all windows on a specific display
    func getWindowsOnDisplay(_ displayID: CGDirectDisplayID) -> [WindowID] {
        let displayBounds = CGDisplayBounds(displayID)

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else { return [] }

        var windowsOnDisplay: [WindowID] = []

        for info in windowList {
            guard let windowID = info[kCGWindowNumber] as? WindowID,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"] else {
                continue
            }

            // Check if window origin is within display bounds
            let windowOrigin = CGPoint(x: x, y: y)
            if displayBounds.contains(windowOrigin) { windowsOnDisplay.append(windowID) }
        }

        return windowsOnDisplay
    }
}

// MARK: - Accessibility Integration

extension WindowSpaceManager {
    /// Resize a window using Accessibility API
    /// This is more reliable than CGS APIs for some apps
    func resizeWindowViaAccessibility(
        _ windowID: WindowID,
        to size: CGSize,
        axElement: AXUIElement? = nil
    )
    async -> Bool {
        // If no AX element provided, we can't resize via accessibility
        guard let element = axElement else {
            MirageLogger.debug(.host, "No AXUIElement provided for window \(windowID)")
            return false
        }

        // Set position first (some apps require this)
        var position = CGPoint.zero
        var positionValue = AXValueCreate(.cgPoint, &position)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue as CFTypeRef)

        // Set size
        var mutableSize = size
        var sizeValue = AXValueCreate(.cgSize, &mutableSize)
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue as CFTypeRef)

        if result == .success {
            MirageLogger.host("Resized window \(windowID) to \(size) via Accessibility")
            return true
        } else {
            MirageLogger.debug(.host, "Failed to resize window \(windowID) via Accessibility: \(result)")
            return false
        }
    }
}

#endif
