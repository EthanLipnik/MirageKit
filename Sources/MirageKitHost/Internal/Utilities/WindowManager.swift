//
//  WindowManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

/// Utility for managing windows via the Accessibility API
enum WindowManager {
    private static let fullScreenAttribute = "AXFullScreen"

    /// Minimizes a window by its WindowID
    /// - Parameter windowID: The WindowID of the window to minimize
    /// - Returns: true if the window was successfully minimized, false otherwise
    @discardableResult
    static func minimizeWindow(_ windowID: WindowID) -> Bool {
        setWindowMinimized(windowID, minimized: true)
    }

    /// Restores a minimized window by its WindowID.
    /// - Parameter windowID: The WindowID of the window to restore
    /// - Returns: true if the window was successfully restored, false otherwise
    @discardableResult
    static func restoreWindow(_ windowID: WindowID) -> Bool {
        setWindowMinimized(windowID, minimized: false)
    }

    /// Returns whether a window is currently in macOS full-screen mode.
    static func isWindowFullScreen(_ windowID: WindowID) -> Bool {
        guard let axWindow = resolveAXWindow(windowID) else { return false }
        return axBooleanAttributeValue(axWindow, attribute: fullScreenAttribute as CFString) ?? false
    }

    /// Exits macOS full-screen mode for a window when supported.
    /// - Parameter windowID: The WindowID of the window to exit full-screen mode.
    /// - Returns: true if a full-screen window was toggled out of that state.
    @discardableResult
    static func exitFullScreen(_ windowID: WindowID) -> Bool {
        setWindowFullScreen(windowID, fullScreen: false)
    }

    @discardableResult
    private static func setWindowMinimized(_ windowID: WindowID, minimized: Bool) -> Bool {
        let action = minimized ? "minimize" : "restore"
        guard let axWindow = resolveAXWindow(windowID) else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID) to \(action)")
            return false
        }

        let targetValue: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            targetValue
        )

        if result == .success {
            MirageLogger.host("WindowManager: Successfully \(minimized ? "minimized" : "restored") window \(windowID)")
            return true
        }

        MirageLogger.host("WindowManager: Failed to \(action) window \(windowID): AXError \(result.rawValue)")
        return false
    }

    @discardableResult
    private static func setWindowFullScreen(_ windowID: WindowID, fullScreen: Bool) -> Bool {
        let action = fullScreen ? "enter full screen" : "exit full screen"
        guard let axWindow = resolveAXWindow(windowID) else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID) to \(action)")
            return false
        }

        guard let currentValue = axBooleanAttributeValue(
            axWindow,
            attribute: fullScreenAttribute as CFString
        ) else {
            MirageLogger.host("WindowManager: Full-screen state unavailable for window \(windowID)")
            return false
        }

        guard currentValue != fullScreen else { return false }

        let targetValue: CFTypeRef = fullScreen ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(
            axWindow,
            fullScreenAttribute as CFString,
            targetValue
        )

        if result == .success {
            MirageLogger.host("WindowManager: Successfully toggled full-screen state for window \(windowID)")
            return true
        }

        MirageLogger.host("WindowManager: Failed to \(action) for window \(windowID): AXError \(result.rawValue)")
        return false
    }

    private static func axBooleanAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
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

    private static func resolveAXWindow(_ windowID: WindowID) -> AXUIElement? {
        // Get window info from CGWindowList to find owner PID and position
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }) else {
            MirageLogger.host("WindowManager: Could not find window \(windowID) in window list")
            return nil
        }

        // Get the owner PID
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
            MirageLogger.host("WindowManager: Could not get owner PID for window \(windowID)")
            return nil
        }

        // Validate process is still running
        guard NSRunningApplication(processIdentifier: ownerPID) != nil else {
            MirageLogger.host("WindowManager: Process \(ownerPID) is no longer running")
            return nil
        }

        // Get the window's position for matching
        guard let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
            MirageLogger.host("WindowManager: Could not get bounds for window \(windowID)")
            return nil
        }
        let windowX = windowBounds["X"] as? CGFloat
        let windowY = windowBounds["Y"] as? CGFloat

        // Create AX element for the app
        let appElement = AXUIElementCreateApplication(ownerPID)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            MirageLogger.host("WindowManager: Could not get AX windows for PID \(ownerPID): AXError \(result.rawValue)")
            return nil
        }

        // Find the matching window
        var targetWindow: AXUIElement?

        if axWindows.count == 1 {
            // Only one window, use it directly
            targetWindow = axWindows[0]
        } else if let windowX, let windowY {
            // Match by position
            for axWindow in axWindows {
                var positionRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)

                if let positionValue = positionRef {
                    var position = CGPoint.zero
                    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

                    // Allow small tolerance for floating point comparison
                    if abs(position.x - windowX) < 1.0, abs(position.y - windowY) < 1.0 {
                        targetWindow = axWindow
                        break
                    }
                }
            }
        }

        // Fall back to first window if no match found
        if targetWindow == nil, !axWindows.isEmpty {
            MirageLogger.host("WindowManager: Could not match window by position, using first window")
            targetWindow = axWindows[0]
        }

        guard let axWindow = targetWindow else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID)")
            return nil
        }

        return axWindow
    }
}
#endif
