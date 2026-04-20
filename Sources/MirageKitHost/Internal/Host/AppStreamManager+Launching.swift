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

enum AppStreamLaunchOutcome: Equatable, Sendable {
    case launched
    case alreadyRunning
    case failed
}

enum AppStreamReopenAction: Equatable, Sendable {
    case activateRunningApplication
    case sendReopenAppleEvent
    case openApplication
    case openURLFallback
}

extension AppStreamManager {
    // MARK: - App Launching

    nonisolated static func reopenActions(
        hasRunningApplication: Bool,
        hasApplicationURL: Bool
    ) -> [AppStreamReopenAction] {
        guard hasApplicationURL else {
            return hasRunningApplication ? [.activateRunningApplication, .sendReopenAppleEvent] : []
        }

        if hasRunningApplication {
            return [.activateRunningApplication, .sendReopenAppleEvent, .openApplication, .openURLFallback]
        }
        return [.openApplication, .openURLFallback]
    }

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
    /// - Returns: Whether the app was newly launched, already running, or failed to launch.
    func launchAppIfNeeded(_ bundleIdentifier: String, path: String) async -> AppStreamLaunchOutcome {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }) {
            runningApp.activate()
            logger.debug("App \(bundleIdentifier) already running")
            return .alreadyRunning
        }

        guard let url = resolvedApplicationURL(bundleIdentifier: bundleIdentifier, path: path) else {
            logger.error("Failed to resolve launch URL for app \(bundleIdentifier)")
            return .failed
        }

        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            logger.info("Launched app: \(bundleIdentifier)")
            return .launched
        } catch {
            logger.warning("openApplication failed for \(bundleIdentifier): \(error); trying open(url) fallback")
        }

        // Fallback for apps with complex launcher architectures (e.g. Docker Desktop, Electron apps)
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.open(url, configuration: config)
            logger.info("Launched app via open(url) fallback: \(bundleIdentifier)")
            return .launched
        } catch {
            logger.error("Failed to launch app \(bundleIdentifier): \(error)")
            return .failed
        }
    }

    /// Request a new window from an app (for apps that are running but have no windows)
    func requestNewWindow(bundleIdentifier: String, path: String? = nil) async {
        let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        })
        let appURL = runningApp?.bundleURL ?? resolvedApplicationURL(
            bundleIdentifier: bundleIdentifier,
            path: path
        )
        let actions = Self.reopenActions(
            hasRunningApplication: runningApp != nil,
            hasApplicationURL: appURL != nil
        )
        guard !actions.isEmpty else {
            logger.warning("Failed to resolve app URL for launch request: \(bundleIdentifier)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        for action in actions {
            switch action {
            case .activateRunningApplication:
                runningApp?.activate()

            case .sendReopenAppleEvent:
                guard let runningApp else { continue }
                if Self.sendReopenAppleEvent(to: runningApp) {
                    logger.info("Sent native reopen Apple Event to app: \(bundleIdentifier)")
                    return
                }
                logger.warning("Native reopen Apple Event failed for app \(bundleIdentifier); trying workspace fallback")

            case .openApplication:
                guard let appURL else { continue }
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                    let verb = runningApp == nil ? "Launched app while requesting first window" : "Requested reopen/new window for app"
                    logger.info("\(verb): \(bundleIdentifier)")
                    return
                } catch {
                    let verb = runningApp == nil ? "launch" : "reopen"
                    logger.warning(
                        "openApplication \(verb) failed for \(bundleIdentifier): \(error); trying open(url) fallback"
                    )
                }

            case .openURLFallback:
                guard let appURL else { continue }
                do {
                    _ = try await NSWorkspace.shared.open(appURL, configuration: configuration)
                    let verb = runningApp == nil
                        ? "Launched app via open(url) fallback while requesting first window"
                        : "Requested reopen/new window via open(url) fallback for app"
                    logger.info("\(verb): \(bundleIdentifier)")
                    return
                } catch {
                    logger.warning("Failed to request reopen/new window for app \(bundleIdentifier): \(error)")
                }
            }
        }
    }

    @discardableResult
    nonisolated private static func sendReopenAppleEvent(to runningApp: NSRunningApplication) -> Bool {
        let target = NSAppleEventDescriptor(processIdentifier: runningApp.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        do {
            _ = try event.sendEvent(options: [.noReply, .canSwitchLayer], timeout: 1)
            return true
        } catch {
            return false
        }
    }
}

#endif
