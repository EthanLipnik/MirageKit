//
//  AppStreamManager+Resizability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager extensions.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation

// MARK: - Window Resizability Check

public extension AppStreamManager {
    /// Check if a window is resizable using Accessibility API
    /// Checks if the kAXSizeAttribute is settable for the window
    nonisolated func checkWindowResizability(windowID _: WindowID, processID: Int32) -> Bool {
        let appElement = AXUIElementCreateApplication(processID)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return true // Assume resizable if we can't check
        }

        // For simplicity, check the first window - in practice we'd need to match by window ID
        // which requires private API. Most apps have consistent resizability across windows.
        guard let axWindow = windows.first else { return true }

        // Check if size attribute is settable
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSettable)

        if result == .success { return isSettable.boolValue }

        return true // Default to resizable
    }
}

#endif
