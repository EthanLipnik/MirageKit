//
//  AppStreamManager+Launching.swift
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

public extension AppStreamManager {
    // MARK: - App Launching

    /// Launch an app if not running
    /// - Parameter bundleIdentifier: The app to launch
    /// - Returns: True if app was launched or already running
    func launchAppIfNeeded(_ bundleIdentifier: String, path: String) async -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }

        if isRunning {
            logger.debug("App \(bundleIdentifier) already running")
            return true
        }

        do {
            let url = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            logger.info("Launched app: \(bundleIdentifier)")
            return true
        } catch {
            logger.error("Failed to launch app \(bundleIdentifier): \(error)")
            return false
        }
    }

    /// Request a new window from an app (for apps that are running but have no windows)
    func requestNewWindow(bundleIdentifier: String) async {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) else {
            return
        }

        // Activate the app first
        app.activate()

        // Try to send "New Window" command via Apple Events
        let script = """
        tell application id "\(bundleIdentifier)"
            try
                make new document
            on error
                try
                    activate
                end try
            end try
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error { logger.warning("Apple Script error requesting new window: \(error)") }
        }
    }
}

#endif
