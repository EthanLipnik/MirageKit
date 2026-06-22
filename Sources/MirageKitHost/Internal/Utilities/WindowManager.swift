//
//  WindowManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
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
import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
import ApplicationServices

/// Utility for managing windows via the Accessibility API
enum WindowManager {
    private static let fullScreenAttribute = "AXFullScreen"

    /// Attempts to minimize a window when failure should only be logged by the accessibility layer.
    static func minimizeWindowIfPossible(_ windowID: WindowID) {
        _ = setWindowMinimized(windowID, minimized: true)
    }

    /// Restores a minimized window by its WindowID.
    /// - Parameter windowID: The WindowID of the window to restore
    /// - Returns: true if the window was successfully restored, false otherwise
    static func restoreWindow(_ windowID: WindowID) -> Bool {
        setWindowMinimized(windowID, minimized: false)
    }

    /// Returns whether a window is currently in macOS full-screen mode.
    static func isWindowFullScreen(_ windowID: WindowID) -> Bool {
        guard let axWindow = resolveAXWindow(windowID) else { return false }
        return HostAccessibilityWindowLookup.boolAttribute(fullScreenAttribute as CFString, from: axWindow) ?? false
    }

    /// Exits macOS full-screen mode for a window when supported.
    /// - Parameter windowID: The WindowID of the window to exit full-screen mode.
    /// - Returns: true if a full-screen window was toggled out of that state.
    static func exitFullScreen(_ windowID: WindowID) -> Bool {
        setWindowFullScreen(windowID, fullScreen: false)
    }

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

    private static func setWindowFullScreen(_ windowID: WindowID, fullScreen: Bool) -> Bool {
        let action = fullScreen ? "enter full screen" : "exit full screen"
        guard let axWindow = resolveAXWindow(windowID) else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID) to \(action)")
            return false
        }

        guard let currentValue = HostAccessibilityWindowLookup.boolAttribute(
            fullScreenAttribute as CFString,
            from: axWindow
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

        let appElement = AXUIElementCreateApplication(ownerPID)
        let axWindows = HostAccessibilityWindowLookup.windows(in: appElement)

        guard !axWindows.isEmpty else {
            MirageLogger.host("WindowManager: Could not get AX windows for PID \(ownerPID)")
            return nil
        }

        var targetWindow: AXUIElement?
        if let exactWindow = HostAccessibilityWindowLookup.window(matching: windowID, in: axWindows) {
            targetWindow = exactWindow
        } else if axWindows.count == 1 {
            targetWindow = axWindows.first
        } else if let windowX, let windowY {
            for axWindow in axWindows {
                guard let position = HostAccessibilityWindowLookup.position(of: axWindow) else { continue }
                if abs(position.x - windowX) < 1.0, abs(position.y - windowY) < 1.0 {
                    targetWindow = axWindow
                    break
                }
            }
        }

        if targetWindow == nil, let firstWindow = axWindows.first {
            MirageLogger.host("WindowManager: Could not match window by position, using first window")
            targetWindow = firstWindow
        }

        guard let axWindow = targetWindow else {
            MirageLogger.host("WindowManager: No AX window found for window \(windowID)")
            return nil
        }

        return axWindow
    }
}
#endif
