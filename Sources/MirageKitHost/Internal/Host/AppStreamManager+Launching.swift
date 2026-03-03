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
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) {
            runningApp.activate()
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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) else {
            return
        }

        _ = runningApp.activate()

        guard let appURL = runningApp.bundleURL ??
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            logger.warning("Failed to resolve app URL for reopen request: \(bundleIdentifier)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            logger.info("Requested reopen/new window for app: \(bundleIdentifier)")
        } catch {
            logger.warning("Failed to request reopen/new window for app \(bundleIdentifier): \(error)")
        }
    }
}

#endif
