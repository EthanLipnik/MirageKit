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
        let result = windowActivator.activate(app: app, axWindow: axWindow)

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
        let axWindows = HostAccessibilityWindowLookup.windows(in: appElement)

        guard !axWindows.isEmpty else {
            MirageLogger.host("AX windows query returned no windows for '\(app.name)' (PID: \(app.id))")
            return nil
        }

        if let exactWindow = HostAccessibilityWindowLookup.window(matching: window.id, in: axWindows) {
            return exactWindow
        }

        if axWindows.count == 1 { return axWindows.first }

        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        for axWindow in axWindows {
            guard let position = HostAccessibilityWindowLookup.position(of: axWindow) else { continue }
            if abs(position.x - windowX) < 10, abs(position.y - windowY) < 10 { return axWindow }
        }

        return axWindows.first
    }
}
#endif
