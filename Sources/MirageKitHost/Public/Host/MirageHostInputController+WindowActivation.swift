//
//  MirageHostInputController+WindowActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Window Activation (runs on accessibilityQueue)

    func activateWindow(windowID: WindowID, app: MirageApplication?) {
        guard let app,
              let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            return
        }

        runningApp.activate()

        let appElement = AXUIElementCreateApplication(app.id)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let axWindow = findAXWindowByID(appElement: appElement, windowID: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else {
            Task {
                await MainActor.run {
                    _ = MirageHostService.bringWindowToFront(windowID)
                }
            }
        }
    }

    private func findAXWindowByID(appElement: AXUIElement, windowID: WindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWindow in windows {
            var cgWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success,
               cgWindowID == windowID {
                return axWindow
            }
        }
        return nil
    }
}

#endif
