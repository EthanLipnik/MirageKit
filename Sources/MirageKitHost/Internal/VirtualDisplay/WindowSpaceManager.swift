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
import ApplicationServices

/// Manages window movement between displays/spaces for Mirage streams
/// Handles moving windows to virtual displays and restoring them on stream end
actor WindowSpaceManager {
    // MARK: - Singleton

    static let shared = WindowSpaceManager()

    private init() {}

    // MARK: - Types

    struct TrafficLightVisibilitySnapshot: Sendable {
        let closeHidden: Bool?
        let minimizeHidden: Bool?
        let zoomHidden: Bool?

        var hasRecordedState: Bool {
            closeHidden != nil || minimizeHidden != nil || zoomHidden != nil
        }
    }

    /// Saved state for restoring a window to its original position
    struct SavedWindowState: Sendable {
        let windowID: WindowID
        let originalFrame: CGRect
        let originalSpaceIDs: [CGSSpaceID]
        let trafficLightVisibilitySnapshot: TrafficLightVisibilitySnapshot?
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
            let axWindow = resolveAXWindow(for: windowID)
            let trafficLightVisibilitySnapshot = hideTrafficLightsIfSupported(
                windowID: windowID,
                axWindow: axWindow
            )
            let savedState = SavedWindowState(
                windowID: windowID,
                originalFrame: windowInfo.frame,
                originalSpaceIDs: currentSpaces,
                trafficLightVisibilitySnapshot: trafficLightVisibilitySnapshot,
                savedAt: Date()
            )
            savedStates[windowID] = savedState
            MirageLogger.host("Saving window \(windowID) state: frame=\(windowInfo.frame), spaces=\(currentSpaces)")
        } else {
            MirageLogger.host("Window \(windowID) already has saved state; preserving original state during move")
        }

        let targetOrigin = displayBounds.origin
        let maxAttempts = 4

        for attempt in 1 ... maxAttempts {
            let didActivateSpaceBeforeMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
            if !didActivateSpaceBeforeMove {
                MirageLogger.host("Failed to set current space \(spaceID) for display \(displayID) before move attempt \(attempt)")
            }

            CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
            let didMoveWindow = CGSWindowSpaceBridge.moveWindow(windowID, to: targetOrigin)
            if !didMoveWindow {
                MirageLogger.debug(.host, "Failed to move window \(windowID) to position \(targetOrigin) on attempt \(attempt)")
            }
            if !CGSWindowSpaceBridge.bringWindowToFront(windowID) {
                MirageLogger.debug(.host, "Failed to raise window \(windowID) on move attempt \(attempt)")
            }

            let didActivateSpaceAfterMove = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
            if !didActivateSpaceAfterMove {
                MirageLogger.host("Failed to set current space \(spaceID) for display \(displayID) after move attempt \(attempt)")
            }

            if verifyWindowPlacement(
                windowID,
                expectedSpaceID: spaceID,
                displayBounds: displayBounds,
                targetOrigin: targetOrigin
            ) {
                MirageLogger.host("Moved window \(windowID) to space \(spaceID) at \(targetOrigin) (attempt \(attempt))")
                return
            }

            if attempt < maxAttempts {
                MirageLogger.host(
                    "Window \(windowID) placement not yet confirmed on attempt \(attempt)/\(maxAttempts); retrying"
                )
                try? await Task.sleep(for: .milliseconds(Int64(40 * attempt)))
            }
        }

        throw WindowSpaceError.moveFailed(
            windowID,
            "Placement verification failed for space \(spaceID) on display \(displayID)"
        )
    }

    private func verifyWindowPlacement(
        _ windowID: WindowID,
        expectedSpaceID: CGSSpaceID,
        displayBounds: CGRect,
        targetOrigin: CGPoint
    ) -> Bool {
        let spaces = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
        guard spaces.contains(expectedSpaceID) else { return false }

        guard let windowInfo = getWindowInfo(windowID) else { return true }

        let frame = windowInfo.frame
        let originTolerance: CGFloat = 16
        let originMatches = abs(frame.origin.x - targetOrigin.x) <= originTolerance &&
            abs(frame.origin.y - targetOrigin.y) <= originTolerance
        let expandedBounds = displayBounds.insetBy(dx: -24, dy: -24)
        let intersectsBounds = frame.intersects(expandedBounds)

        return originMatches || intersectsBounds
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

        restoreTrafficLightsIfNeeded(savedState.trafficLightVisibilitySnapshot, windowID: windowID)
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

    private func hideTrafficLightsIfSupported(
        windowID: WindowID,
        axWindow: AXUIElement?
    )
    -> TrafficLightVisibilitySnapshot? {
        guard let axWindow else {
            MirageLogger.debug(.host, "Traffic lights hide unsupported for window \(windowID): AX window unavailable")
            return nil
        }

        let closeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            windowID: windowID
        )
        let minimizeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            windowID: windowID
        )
        let zoomHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            windowID: windowID
        )

        let snapshot = TrafficLightVisibilitySnapshot(
            closeHidden: closeHidden,
            minimizeHidden: minimizeHidden,
            zoomHidden: zoomHidden
        )

        if snapshot.hasRecordedState {
            MirageLogger.host("Applied traffic light hiding for streamed window \(windowID)")
            return snapshot
        }

        MirageLogger.debug(.host, "Traffic lights hide unsupported for window \(windowID): no settable AXHidden buttons")
        return nil
    }

    private func hideTrafficLightButtonIfSupported(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        windowID: WindowID
    )
    -> Bool? {
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): missing \(buttonLabel) button"
            )
            return nil
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard let existingValue = axBooleanAttributeValue(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): \(buttonLabel) AXHidden unavailable"
            )
            return nil
        }

        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide unsupported for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return nil
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: true) else {
            MirageLogger.debug(
                .host,
                "Traffic lights hide failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return nil
        }

        MirageLogger.host("Hid \(buttonLabel) traffic light for streamed window \(windowID)")
        return existingValue
    }

    private func restoreTrafficLightsIfNeeded(_ snapshot: TrafficLightVisibilitySnapshot?, windowID: WindowID) {
        guard let snapshot, snapshot.hasRecordedState else { return }
        guard let axWindow = resolveAXWindow(for: windowID) else {
            MirageLogger.debug(.host, "Traffic lights restore skipped for window \(windowID): AX window unavailable")
            return
        }

        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            hiddenValue: snapshot.closeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            hiddenValue: snapshot.minimizeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            hiddenValue: snapshot.zoomHidden,
            windowID: windowID
        )

        MirageLogger.host("Restored traffic light visibility for streamed window \(windowID)")
    }

    private func restoreTrafficLightButtonIfNeeded(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        hiddenValue: Bool?,
        windowID: WindowID
    ) {
        guard let hiddenValue else { return }
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore skipped for window \(windowID): missing \(buttonLabel) button"
            )
            return
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore skipped for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: hiddenValue) else {
            MirageLogger.debug(
                .host,
                "Traffic lights restore failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return
        }
    }

    private func resolveAXWindow(for windowID: WindowID) -> AXUIElement? {
        guard let windowInfo = getWindowInfo(windowID) else { return nil }
        guard let ownerPID = windowInfo.ownerPID else { return nil }

        let appElement = AXUIElementCreateApplication(ownerPID)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let axWindowsValue = windowsRef,
              let axWindows = axWindowsValue as? [AXUIElement],
              !axWindows.isEmpty else {
            return nil
        }

        if axWindows.count == 1 {
            return axWindows[0]
        }

        let targetFrame = windowInfo.frame
        for axWindow in axWindows {
            guard let frame = axWindowFrame(axWindow) else { continue }
            if abs(frame.origin.x - targetFrame.origin.x) <= 24,
               abs(frame.origin.y - targetFrame.origin.y) <= 24,
               abs(frame.size.width - targetFrame.size.width) <= 24,
               abs(frame.size.height - targetFrame.size.height) <= 24 {
                return axWindow
            }
        }

        return axWindows.first
    }

    private func axWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func axElementAttributeValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func axBooleanAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        return nil
    }

    private func isAXAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func setAXBooleanAttributeValue(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
        let targetValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute, targetValue) == .success
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
    private func getWindowInfo(_ windowID: WindowID) -> (frame: CGRect, title: String?, ownerPID: pid_t?)? {
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
