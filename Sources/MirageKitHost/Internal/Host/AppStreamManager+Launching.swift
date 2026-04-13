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

    private func resolvedApplicationURL(
        bundleIdentifier: String,
        path: String?
    ) -> URL? {
        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

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

        guard let url = resolvedApplicationURL(bundleIdentifier: bundleIdentifier, path: path) else {
            logger.error("Failed to resolve launch URL for app \(bundleIdentifier)")
            return false
        }

        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            logger.info("Launched app: \(bundleIdentifier)")
            return true
        } catch {
            logger.warning("openApplication failed for \(bundleIdentifier): \(error); trying open(url) fallback")
        }

        // Fallback for apps with complex launcher architectures (e.g. Docker Desktop, Electron apps)
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.open(url, configuration: config)
            logger.info("Launched app via open(url) fallback: \(bundleIdentifier)")
            return true
        } catch {
            logger.error("Failed to launch app \(bundleIdentifier): \(error)")
            return false
        }
    }

    /// Request a new window from an app (for apps that are running but have no windows)
    func requestNewWindow(bundleIdentifier: String, path: String? = nil) async {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) {
            runningApp.activate()

            guard let appURL = runningApp.bundleURL ??
                resolvedApplicationURL(bundleIdentifier: bundleIdentifier, path: path) else {
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
                logger.warning(
                    "openApplication reopen failed for app \(bundleIdentifier): \(error); trying open(url) fallback"
                )
                do {
                    _ = try await NSWorkspace.shared.open(appURL, configuration: configuration)
                    logger.info("Requested reopen/new window via open(url) fallback for app: \(bundleIdentifier)")
                } catch {
                    logger.warning("Failed to request reopen/new window for app \(bundleIdentifier): \(error)")
                }
            }
            return
        }

        guard let appURL = resolvedApplicationURL(bundleIdentifier: bundleIdentifier, path: path) else {
            logger.warning("Failed to resolve app URL for launch request: \(bundleIdentifier)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            logger.info("Launched app while requesting first window: \(bundleIdentifier)")
        } catch {
            logger.warning(
                "openApplication launch failed for \(bundleIdentifier) while requesting first window: \(error); trying open(url) fallback"
            )
            do {
                _ = try await NSWorkspace.shared.open(appURL, configuration: configuration)
                logger.info("Launched app via open(url) fallback while requesting first window: \(bundleIdentifier)")
            } catch {
                logger.warning("Failed to launch app \(bundleIdentifier) while requesting first window: \(error)")
            }
        }
    }
}

#endif
