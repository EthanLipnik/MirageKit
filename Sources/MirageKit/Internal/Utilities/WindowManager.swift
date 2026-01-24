//
//  WindowManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

/// Utility for managing windows via the Accessibility API
enum WindowManager {

    /// Minimizes a window by its WindowID
    /// - Parameter windowID: The WindowID of the window to minimize
    /// - Returns: true if the window was successfully minimized, false otherwise
    @discardableResult
    static func minimizeWindow(_ windowID: WindowID) -> Bool {
        // Get window info from CGWindowList to find owner PID and position
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }) else {
            MirageLogger.host("WindowManager: Could not find window \(windowID) in window list")
            return false
        }

        // Get the owner PID
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
            MirageLogger.host("WindowManager: Could not get owner PID for window \(windowID)")
            return false
        }

        // Validate process is still running
        guard NSRunningApplication(processIdentifier: ownerPID) != nil else {
            MirageLogger.host("WindowManager: Process \(ownerPID) is no longer running")
            return false
        }

        // Get the window's position for matching
        guard let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
            MirageLogger.host("WindowManager: Could not get bounds for window \(windowID)")
            return false
        }
        let windowX = windowBounds["X"] as? CGFloat
        let windowY = windowBounds["Y"] as? CGFloat

        // Create AX element for the app
        let appElement = AXUIElementCreateApplication(ownerPID)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            MirageLogger.host("WindowManager: Could not get AX windows for PID \(ownerPID): AXError \(result.rawValue)")
            return false
        }

        // Find the matching window
        var targetWindow: AXUIElement?

        if axWindows.count == 1 {
            // Only one window, use it directly
            targetWindow = axWindows[0]
        } else if let windowX = windowX, let windowY = windowY {
            // Match by position
            for axWindow in axWindows {
                var positionRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)

                if let positionValue = positionRef {
                    var position = CGPoint.zero
                    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

                    // Allow small tolerance for floating point comparison
                    if abs(position.x - windowX) < 1.0 && abs(position.y - windowY) < 1.0 {
                        targetWindow = axWindow
                        break
                    }
                }
            }
        }

        // Fall back to first window if no match found
        if targetWindow == nil && !axWindows.isEmpty {
            MirageLogger.host("WindowManager: Could not match window by position, using first window")
            targetWindow = axWindows[0]
        }

        guard let axWindow = targetWindow else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID)")
            return false
        }

        // Set the minimized attribute
        let minimizeResult = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )

        if minimizeResult == .success {
            MirageLogger.host("WindowManager: Successfully minimized window \(windowID)")
            return true
        } else {
            MirageLogger.host("WindowManager: Failed to minimize window \(windowID): AXError \(minimizeResult.rawValue)")
            return false
        }
    }
}
#endif
