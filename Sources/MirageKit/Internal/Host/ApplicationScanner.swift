//
//  ApplicationScanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

#if os(macOS)
import AppKit
import Foundation
import OSLog

/// Scans installed applications on macOS for streaming selection
/// Based on Vector's AppsService but simplified for Mirage's network-based use case
public actor ApplicationScanner {
    private let logger = Logger(subsystem: "MirageKit", category: "ApplicationScanner")
    private let fileManager = FileManager.default

    /// Directories to scan for applications
    private let scanDirectories: [URL]

    /// Icon size for PNG generation
    private let iconSize: CGFloat = 128

    /// Bundle identifier patterns to exclude (system services, agents, etc.)
    private let excludedBundlePatterns: [String] = [
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
        "XPCService"
    ]

    /// Specific bundle identifiers to always include from CoreServices
    private let coreServicesAllowlist: Set<String> = [
        "com.apple.finder",
        "com.apple.archiveutility",
        "com.apple.ScriptEditor2",  // Script Editor
        "com.apple.grapher",
        "com.apple.ScreenSharing",
        "com.apple.SystemProfiler",  // System Information
        "com.apple.dt.CommandLineTools.installondemand",
        "com.apple.DiskImageMounter"
    ]

    /// Excluded directory names when scanning nested bundles
    private let excludedDirectoryNames: Set<String> = [
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
        "sbin"
    ]

    /// Bundle identifiers that allow nested app scanning (e.g., Xcode contains many apps)
    private let nestedBundleAllowedIdentifiers: Set<String> = [
        "com.apple.dt.xcode"
    ]

    /// Maximum depth for nested bundle scanning
    private let nestedBundleScanDepth = 7

    public init() {
        var directories: Set<URL> = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
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
    ) async -> [MirageInstalledApp] {
        logger.debug("Starting application scan")
        let startTime = Date()

        let candidates = await scanAllDirectories()

        var apps: [MirageInstalledApp] = []
        for candidate in candidates {
            guard let bundleIdentifier = candidate.bundleIdentifier else { continue }

            let iconData: Data? = includeIcons ? await generateIconPNG(for: candidate.url) : nil

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
    ) -> [MirageInstalledApp] {
        apps.map { app in
            var updated = app
            updated.isRunning = runningApps.contains(app.bundleIdentifier.lowercased())
            updated.isBeingStreamed = streamingApps.contains(app.bundleIdentifier.lowercased())
            return updated
        }
    }
}

// MARK: - Directory Scanning

private extension ApplicationScanner {
    struct AppCandidate: Hashable {
        let name: String
        let bundleIdentifier: String?
        let version: String?
        let url: URL
        let path: String
        let domainPriority: Int

        func isPreferred(over other: AppCandidate) -> Bool {
            guard self != other else { return false }

            // Higher domain priority wins
            if domainPriority != other.domainPriority {
                return domainPriority > other.domainPriority
            }

            // Compare versions
            if let comparison = compareVersions(version, other.version), comparison != .orderedSame {
                return comparison == .orderedDescending
            }

            // Fallback to path comparison
            return path.localizedCaseInsensitiveCompare(other.path) == .orderedAscending
        }
    }

    func scanAllDirectories() async -> [AppCandidate] {
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return [] }
            return await self.performDirectoryScan()
        }.value
    }

    func performDirectoryScan() -> [AppCandidate] {
        var byBundle: [String: AppCandidate] = [:]
        var byPath: [String: AppCandidate] = [:]
        var seenPaths = Set<String>()

        for directory in scanDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    NSLog("MirageKit.ApplicationScanner: Failed to enumerate \(url.path): \(error)")
                    return true
                }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard let canonicalURL = processCandidate(
                    at: url,
                    allowBundleContents: false,
                    seenPaths: &seenPaths,
                    byBundle: &byBundle,
                    byPath: &byPath
                ) else {
                    continue
                }

                // Check if we should scan inside this app bundle (e.g., Xcode)
                if allowsScanningBundleContents(at: canonicalURL) {
                    scanNestedApps(
                        inside: canonicalURL,
                        currentDepth: 0,
                        maxDepth: nestedBundleScanDepth,
                        seenPaths: &seenPaths,
                        byBundle: &byBundle,
                        byPath: &byPath
                    )
                }
            }
        }

        return Array(byBundle.values) + Array(byPath.values)
    }

    @discardableResult
    func processCandidate(
        at url: URL,
        allowBundleContents: Bool,
        seenPaths: inout Set<String>,
        byBundle: inout [String: AppCandidate],
        byPath: inout [String: AppCandidate]
    ) -> URL? {
        guard shouldConsiderApp(at: url, allowBundleContents: allowBundleContents) else {
            return nil
        }

        let canonicalURL = canonicalURL(forPath: url.path)
        guard seenPaths.insert(canonicalURL.path).inserted else { return nil }

        guard let candidate = candidateFromBundle(at: canonicalURL) else {
            return canonicalURL
        }

        // Skip apps without bundle identifiers (can't stream them reliably)
        guard let identifier = candidate.bundleIdentifier?.lowercased(), !identifier.isEmpty else {
            return canonicalURL
        }

        // Deduplicate by bundle identifier
        if let existing = byBundle[identifier] {
            if candidate.isPreferred(over: existing) {
                byBundle[identifier] = candidate
            }
        } else {
            byBundle[identifier] = candidate
        }

        return canonicalURL
    }

    func scanNestedApps(
        inside directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        seenPaths: inout Set<String>,
        byBundle: inout [String: AppCandidate],
        byPath: inout [String: AppCandidate]
    ) {
        guard currentDepth < maxDepth else { return }

        let lowercasedPath = directory.path.lowercased()
        if lowercasedPath.contains(".simruntime") ||
            lowercasedPath.contains("coresimulator") ||
            lowercasedPath.contains("runtimeroot") {
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let nextDepth = currentDepth + 1

        for entry in contents {
            let lowercasedName = entry.lastPathComponent.lowercased()
            let pathExtension = entry.pathExtension.lowercased()

            if pathExtension == "app" {
                guard let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    continue
                }

                if let canonicalURL = processCandidate(
                    at: entry,
                    allowBundleContents: true,
                    seenPaths: &seenPaths,
                    byBundle: &byBundle,
                    byPath: &byPath
                ), nextDepth < maxDepth {
                    scanNestedApps(
                        inside: canonicalURL,
                        currentDepth: nextDepth,
                        maxDepth: maxDepth,
                        seenPaths: &seenPaths,
                        byBundle: &byBundle,
                        byPath: &byPath
                    )
                }
                continue
            }

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                continue
            }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                continue
            }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) {
                continue
            }

            // Check for Applications/Utilities subdirectories
            if lowercasedName.contains("applications") || lowercasedName.contains("utilities") {
                collectApplications(
                    inside: entry,
                    currentDepth: nextDepth,
                    maxDepth: maxDepth,
                    seenPaths: &seenPaths,
                    byBundle: &byBundle,
                    byPath: &byPath
                )
                continue
            }

            // Descend through transit directories
            if shouldDescendThroughTransitDirectory(named: lowercasedName) {
                scanNestedApps(
                    inside: entry,
                    currentDepth: nextDepth,
                    maxDepth: maxDepth,
                    seenPaths: &seenPaths,
                    byBundle: &byBundle,
                    byPath: &byPath
                )
            }
        }
    }

    func collectApplications(
        inside directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        seenPaths: inout Set<String>,
        byBundle: inout [String: AppCandidate],
        byPath: inout [String: AppCandidate]
    ) {
        guard currentDepth < maxDepth else { return }

        let lowercasedPath = directory.path.lowercased()
        if lowercasedPath.contains(".simruntime") ||
            lowercasedPath.contains("coresimulator") ||
            lowercasedPath.contains("runtimeroot") {
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let nextDepth = currentDepth + 1

        for entry in contents {
            let pathExtension = entry.pathExtension.lowercased()

            if pathExtension == "app" {
                guard let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    continue
                }

                if let canonicalURL = processCandidate(
                    at: entry,
                    allowBundleContents: true,
                    seenPaths: &seenPaths,
                    byBundle: &byBundle,
                    byPath: &byPath
                ), nextDepth < maxDepth {
                    scanNestedApps(
                        inside: canonicalURL,
                        currentDepth: nextDepth,
                        maxDepth: maxDepth,
                        seenPaths: &seenPaths,
                        byBundle: &byBundle,
                        byPath: &byPath
                    )
                }
                continue
            }

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                continue
            }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                continue
            }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) {
                continue
            }

            // Continue collecting in subdirectories
            collectApplications(
                inside: entry,
                currentDepth: nextDepth,
                maxDepth: maxDepth,
                seenPaths: &seenPaths,
                byBundle: &byBundle,
                byPath: &byPath
            )
        }
    }

    func candidateFromBundle(at url: URL) -> AppCandidate? {
        guard let bundle = Bundle(url: url) else {
            return AppCandidate(
                name: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: nil,
                version: nil,
                url: url,
                path: url.path,
                domainPriority: domainPriority(for: url)
            )
        }

        // Skip Mirage itself
        if bundle.bundleIdentifier == "com.ethanlipnik.Mirage" {
            return nil
        }

        let bundleId = bundle.bundleIdentifier ?? ""
        let isCoreServices = url.path.hasPrefix("/System/Library/CoreServices")

        // For CoreServices apps, use allowlist/blocklist filtering
        if isCoreServices {
            let lowercasedId = bundleId.lowercased()

            // Always include apps on the allowlist
            let isAllowlisted = coreServicesAllowlist.contains(lowercasedId)

            // Exclude apps matching system service patterns
            let matchesExclusionPattern = excludedBundlePatterns.contains { pattern in
                bundleId.contains(pattern)
            }

            // Skip if not allowlisted and matches exclusion pattern
            if !isAllowlisted && matchesExclusionPattern {
                return nil
            }

            // Also skip apps with no UI (background-only apps)
            if !isAllowlisted {
                let isBackgroundOnly = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
                    || bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true
                if isBackgroundOnly {
                    return nil
                }
            }
        }

        var displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        if displayName?.isEmpty ?? true {
            displayName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        }
        if displayName?.isEmpty ?? true {
            displayName = url.deletingPathExtension().lastPathComponent
        }

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        return AppCandidate(
            name: displayName ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle.bundleIdentifier,
            version: version,
            url: url,
            path: url.path,
            domainPriority: domainPriority(for: url)
        )
    }
}

// MARK: - Filtering Logic

private extension ApplicationScanner {
    func shouldConsiderApp(at url: URL, allowBundleContents: Bool) -> Bool {
        guard url.pathExtension.lowercased() == "app" else {
            return false
        }

        if !allowBundleContents, url.path.contains("/Contents/") {
            return false
        }

        guard allowBundleContents else {
            return true
        }

        let components = url.pathComponents.map { $0.lowercased() }
        let residesInApplications = components.contains { component in
            component.contains("applications") || component.contains("utilities")
        }

        if !residesInApplications {
            return false
        }

        let isSimulatorRuntime = components.contains { component in
            component.contains(".simruntime") ||
            component.contains("coresimulator") ||
            component.contains("runtimeroot")
        }

        return !isSimulatorRuntime
    }

    func shouldIgnoreNestedDirectory(named name: String) -> Bool {
        let lowercased = name.lowercased()

        if excludedDirectoryNames.contains(lowercased) {
            return true
        }

        if lowercased.hasSuffix(".lproj") || lowercased.hasSuffix(".bundle") {
            return true
        }

        if lowercased.hasPrefix(".") {
            return true
        }

        return false
    }

    func shouldDescendThroughTransitDirectory(named name: String) -> Bool {
        if name.hasSuffix(".platform") {
            return true
        }

        switch name {
        case "contents", "developer", "platforms", "resources", "sharedsupport", "support", "extras":
            return true
        default:
            return false
        }
    }

    func allowsScanningBundleContents(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else {
            return false
        }

        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier?.lowercased() else {
            return false
        }

        return nestedBundleAllowedIdentifiers.contains(identifier)
    }
}

// MARK: - Helpers

private extension ApplicationScanner {
    func canonicalURL(forPath path: String) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return url.resolvingSymlinksInPath()
    }

    func domainPriority(for url: URL) -> Int {
        let path = url.path

        if path.hasPrefix("/System/Applications/") || path == "/System/Applications" {
            return 5
        }
        if path.hasPrefix("/System/Cryptexes/App/System/Applications/") {
            return 5
        }
        if path.hasPrefix("/Applications/") || path == "/Applications" {
            return 4
        }
        if path.hasPrefix("/System/Library/CoreServices/") {
            return 3
        }

        let userApplications = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        if path.hasPrefix(userApplications) {
            return 2
        }

        return 1
    }

    func generateIconPNG(for url: URL) async -> Data? {
        let size = iconSize
        return await MainActor.run {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return Self.rasterizeIconToPNG(icon, size: size)
        }
    }

    nonisolated static func rasterizeIconToPNG(_ icon: NSImage, size: CGFloat) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let scaledImage = NSImage(size: targetSize)

        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        scaledImage.unlockFocus()

        guard let tiffData = scaledImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Version Comparison

private func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
    switch (lhs, rhs) {
    case (nil, nil):
        return .orderedSame
    case let (lhs?, rhs?):
        if lhs == rhs {
            return .orderedSame
        }

        let lhsComponents = lhs.split(separator: ".")
        let rhsComponents = rhs.split(separator: ".")
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : "0"
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : "0"

            if let lhsInt = Int(lhsValue), let rhsInt = Int(rhsValue) {
                if lhsInt != rhsInt {
                    return lhsInt < rhsInt ? .orderedAscending : .orderedDescending
                }
            } else {
                let comparison = lhsValue.localizedStandardCompare(rhsValue)
                if comparison != .orderedSame {
                    return comparison
                }
            }
        }

        return .orderedSame
    case (nil, .some):
        return .orderedAscending
    case (.some, nil):
        return .orderedDescending
    }
}
#endif
