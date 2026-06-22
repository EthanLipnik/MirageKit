//
//  MirageHostWindowController+AXWindows.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Accessibility window lookup and caching for host window control.
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

extension MirageHostWindowController {
    // MARK: - AX Window Caching

    /// Returns a cached AX window element or looks it up if needed.
    func cachedAXWindow(for window: MirageMedia.MirageWindow) -> AXUIElement? {
        if let cached = cachedAXWindows[window.id] { return cached }

        guard let axWindow = findAXWindow(for: window) else { return nil }

        cachedAXWindows[window.id] = axWindow
        return axWindow
    }

    private func findAXWindow(for window: MirageMedia.MirageWindow) -> AXUIElement? {
        guard let app = window.application else { return nil }

        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            cachedAXWindows.removeValue(forKey: window.id)
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.id)
        if let exactWindow = HostAccessibilityWindowLookup.window(in: appElement, matching: window.id) {
            return exactWindow
        }

        let axWindows = HostAccessibilityWindowLookup.windows(in: appElement)
        guard !axWindows.isEmpty else { return nil }

        if axWindows.count == 1 { return axWindows.first }

        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        for axWindow in axWindows {
            if let position = HostAccessibilityWindowLookup.position(of: axWindow) {
                if abs(position.x - windowX) < 10, abs(position.y - windowY) < 10 { return axWindow }
            }
        }

        return axWindows.first
    }
}
#endif
