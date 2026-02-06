import MirageKit
#if os(macOS)

//
//  UnlockManager+LoginWindow.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Login Window Detection

    /// Check if loginwindow or screensaver windows are visible at shielding level
    /// This indicates the lock/login screen is ready to receive input
    private func isLoginWindowVisible() -> Bool {
        let shieldingLevel = CGShieldingWindowLevel()
        let screenSaverLevel = CGWindowLevelForKey(.screenSaverWindow)

        func containsLoginWindow(in windowList: [[String: Any]]) -> Bool {
            for window in windowList {
                guard let ownerName = window[kCGWindowOwnerName as String] as? String else { continue }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0

                if ownerName == "loginwindow" || ownerName == "LoginWindow" {
                    if layer >= shieldingLevel { return true }
                }

                if ownerName == "ScreenSaverEngine", layer >= screenSaverLevel { return true }
            }
            return false
        }

        // Check on-screen windows first
        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: onScreen) {
            return true
        }

        // Also check all windows (loginwindow may not be "on screen" on virtual displays)
        if let allWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
           containsLoginWindow(in: allWindows) {
            MirageLogger.host("Login window detected in off-screen window list")
            return true
        }

        return false
    }

    /// Wait for loginwindow to render on the virtual display
    /// This ensures HID events will be delivered to loginwindow instead of being queued
    func waitForLoginWindowReady(timeout: TimeInterval = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var pollCount = 0

        MirageLogger.host("Waiting for loginwindow to render (timeout: \(timeout)s)")

        while Date() < deadline {
            pollCount += 1
            if isLoginWindowVisible() {
                MirageLogger.host("Login window ready after \(pollCount) polls")
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        MirageLogger.error(.host, "Login window not detected after \(timeout)s (\(pollCount) polls)")
        return false
    }
}

#endif
