//
//  ApplicationScanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
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
#if os(macOS)
import CoreGraphics
import Foundation
import OSLog

/// Scans macOS application bundles and returns streamable app metadata for clients.
public actor ApplicationScanner {
    let logger = Logger(subsystem: "MirageKit", category: "ApplicationScanner")
    let fileManager = FileManager.default

    /// Root directories scanned for application bundles.
    let scanDirectories: [URL]

    /// Pixel size used for app list PNG icons.
    let iconSize: CGFloat = 128

    /// Bundle identifier substrings excluded from CoreServices unless allowlisted.
    let excludedBundlePatterns: [String] = [
        "UIServer",
        "UIAgent",
        "UIService",
        "Agent",
        "Helper",
        "Stub",
        "Handler",
        "Forwarder",
        "Installer",
        "Assistant",
        "Launcher",
        "Listener",
        "Daemon",
        "XPCService",
    ]

    /// CoreServices bundle identifiers that should appear in the streamable app list.
    let coreServicesAllowlist: Set<String> = [
        "com.apple.finder",
        "com.apple.archiveutility",
        "com.apple.ScriptEditor2", // Script Editor
        "com.apple.grapher",
        "com.apple.ScreenSharing",
        "com.apple.SystemProfiler", // System Information
        "com.apple.dt.CommandLineTools.installondemand",
        "com.apple.DiskImageMounter",
    ]

    /// Directory names skipped when recursively scanning inside allowed bundles.
    let excludedDirectoryNames: Set<String> = [
        "frameworks",
        "sharedframeworks",
        "privateframeworks",
        "macos",
        "macosclassic",
        "xpcservices",
        "plugins",
        "plug-ins",
        "extensions",
        "helpers",
        "loginitems",
        "watch",
        "library",
        "documentation",
        "samples",
        "examples",
        "templates",
        "toolchains",
        "symbols",
        "coresimulator",
        "runtimeroot",
        "runtimes",
        "runtime",
        "usr",
        "bin",
        "sbin",
    ]

    /// App bundle identifiers whose contents may contain streamable nested apps.
    let nestedBundleAllowedIdentifiers: Set<String> = [
        "com.apple.dt.xcode",
    ]

    /// Maximum recursive depth for nested bundle scans.
    let nestedBundleScanDepth = 7

    /// Creates an application scanner with the standard macOS application search roots.
    public init() {
        var directories: Set<URL> = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        ]

        let userApplications = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        directories.insert(userApplications)

        scanDirectories = Array(directories)
    }

    /// Scans application directories and returns installed apps sorted by display name.
    public func scanInstalledApps(
        includeIcons: Bool = true,
        runningApps: Set<String> = [],
        streamingApps: Set<String> = [],
        onAppDiscovered: (@Sendable (MirageWire.MirageInstalledApp) async -> Void)? = nil
    )
    async -> [MirageWire.MirageInstalledApp] {
        logger.debug("Starting application scan")
        let startTime = Date()

        let candidates = await scanAllDirectories { candidate in
            guard let app = await self.installedApp(
                from: candidate,
                includeIcons: includeIcons,
                runningApps: runningApps,
                streamingApps: streamingApps
            ) else {
                return
            }
            await onAppDiscovered?(app)
        }
        if Task.isCancelled { return [] }

        var apps: [MirageWire.MirageInstalledApp] = []
        for candidate in candidates {
            if Task.isCancelled { return [] }
            guard let app = await installedApp(
                from: candidate,
                includeIcons: includeIcons,
                runningApps: runningApps,
                streamingApps: streamingApps
            ) else { continue }
            apps.append(app)
        }

        // Sort by name
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.debug("Scan complete: \(apps.count) apps in \(elapsed, privacy: .public)s")

        return apps
    }

    /// Enriches a candidate with icon data and current running/streaming state.
    private func installedApp(
        from candidate: AppCandidate,
        includeIcons: Bool,
        runningApps: Set<String>,
        streamingApps: Set<String>
    ) async -> MirageWire.MirageInstalledApp? {
        guard let bundleIdentifier = candidate.bundleIdentifier else { return nil }

        let iconData: Data? = includeIcons ? await generateIconPNG(for: candidate.url) : nil
        if Task.isCancelled { return nil }

        return MirageWire.MirageInstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: candidate.name,
            path: candidate.path,
            iconData: iconData,
            version: candidate.version,
            isRunning: runningApps.contains(bundleIdentifier.lowercased()),
            isBeingStreamed: streamingApps.contains(bundleIdentifier.lowercased())
        )
    }

    /// Updates running and streaming status on an existing app list without rescanning the filesystem.
    public func updateStatus(
        for apps: [MirageWire.MirageInstalledApp],
        runningApps: Set<String>,
        streamingApps: Set<String>
    )
    -> [MirageWire.MirageInstalledApp] {
        apps.map { app in
            var updated = app
            updated.isRunning = runningApps.contains(app.bundleIdentifier.lowercased())
            updated.isBeingStreamed = streamingApps.contains(app.bundleIdentifier.lowercased())
            return updated
        }
    }
}

#endif
