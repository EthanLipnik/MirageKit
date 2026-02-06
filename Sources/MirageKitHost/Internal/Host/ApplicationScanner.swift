//
//  ApplicationScanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import Foundation
import OSLog

/// Scans installed applications on macOS for streaming selection
/// Based on Vector's AppsService but simplified for Mirage's network-based use case
public actor ApplicationScanner {
    let logger = Logger(subsystem: "MirageKit", category: "ApplicationScanner")
    let fileManager = FileManager.default

    /// Directories to scan for applications
    let scanDirectories: [URL]

    /// Icon size for PNG generation
    let iconSize: CGFloat = 128

    /// Bundle identifier patterns to exclude (system services, agents, etc.)
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

    /// Specific bundle identifiers to always include from CoreServices
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

    /// Excluded directory names when scanning nested bundles
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

    /// Bundle identifiers that allow nested app scanning (e.g., Xcode contains many apps)
    let nestedBundleAllowedIdentifiers: Set<String> = [
        "com.apple.dt.xcode",
    ]

    /// Maximum depth for nested bundle scanning
    let nestedBundleScanDepth = 7

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

    /// Scans all application directories and returns installed apps
    /// - Parameters:
    ///   - includeIcons: Whether to include PNG icon data (slower but needed for client display)
    ///   - runningApps: Set of bundle identifiers for currently running apps
    ///   - streamingApps: Set of bundle identifiers for apps currently being streamed
    /// - Returns: Array of installed apps, sorted by name
    public func scanInstalledApps(
        includeIcons: Bool = true,
        runningApps: Set<String> = [],
        streamingApps: Set<String> = []
    )
    async -> [MirageInstalledApp] {
        logger.debug("Starting application scan")
        let startTime = Date()

        let candidates = await scanAllDirectories()
        if Task.isCancelled { return [] }

        var apps: [MirageInstalledApp] = []
        for candidate in candidates {
            if Task.isCancelled { return [] }
            guard let bundleIdentifier = candidate.bundleIdentifier else { continue }

            let iconData: Data? = includeIcons ? await generateIconPNG(for: candidate.url) : nil
            if Task.isCancelled { return [] }

            let app = MirageInstalledApp(
                bundleIdentifier: bundleIdentifier,
                name: candidate.name,
                path: candidate.path,
                iconData: iconData,
                version: candidate.version,
                isRunning: runningApps.contains(bundleIdentifier.lowercased()),
                isBeingStreamed: streamingApps.contains(bundleIdentifier.lowercased())
            )
            apps.append(app)
        }

        // Sort by name
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.debug("Scan complete: \(apps.count) apps in \(elapsed, privacy: .public)s")

        return apps
    }

    /// Updates running/streaming status without rescanning
    public func updateStatus(
        for apps: [MirageInstalledApp],
        runningApps: Set<String>,
        streamingApps: Set<String>
    )
    -> [MirageInstalledApp] {
        apps.map { app in
            var updated = app
            updated.isRunning = runningApps.contains(app.bundleIdentifier.lowercased())
            updated.isBeingStreamed = streamingApps.contains(app.bundleIdentifier.lowercased())
            return updated
        }
    }
}

#endif
