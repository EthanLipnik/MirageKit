//
//  MirageHostService+WindowActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window activation helpers.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostService {
    func activateWindow(_ window: MirageWindow) {
        guard let app = window.application else {
            MirageLogger.host("Cannot activate window - no associated application")
            return
        }

        // Get the AX window if available (for raising specific window)
        let axWindow = findAXWindow(for: window)

        // Use robust multi-method activation
        let result = windowActivator.activate(app: app, window: window, axWindow: axWindow)

        switch result {
        case let .success(method):
            MirageLogger.host("Window activated via \(method)")
        case let .partialSuccess(method, message):
            MirageLogger.host("Window partially activated via \(method): \(message)")
        case let .failure(_, error):
            MirageLogger.error(.host, "Window activation failed: \(error)")
        }
    }

    private func findAXWindow(for window: MirageWindow) -> AXUIElement? {
        guard let app = window.application else {
            MirageLogger.host("Window has no associated application")
            return nil
        }

        // Validate process is still running before attempting AX access
        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            MirageLogger.host("Process \(app.id) (\(app.name)) is no longer running")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.id)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            // Log the actual error for debugging
            MirageLogger.host("AX windows query failed for '\(app.name)' (PID: \(app.id)): AXError \(result.rawValue)")
            switch result {
            case .apiDisabled:
                MirageLogger.host("Accessibility API is disabled in System Preferences")
            case .invalidUIElement:
                MirageLogger.host("Invalid UI element - process may have terminated or restarted")
            case .cannotComplete:
                MirageLogger.host("Cannot complete - app may be unresponsive")
            case .notImplemented:
                MirageLogger.host("App does not implement accessibility for windows")
            case .noValue:
                MirageLogger.host("App returned no windows via accessibility")
            default:
                break
            }
            return nil
        }

        // Single window - use it directly
        if axWindows.count == 1 { return axWindows[0] }

        // Get window position from CGWindowList using the known window ID
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        // Match by position
        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)

            if let positionValue = positionRef {
                var position = CGPoint.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

                if abs(position.x - windowX) < 10, abs(position.y - windowY) < 10 { return axWindow }
            }
        }

        return axWindows.first
    }
}
#endif
