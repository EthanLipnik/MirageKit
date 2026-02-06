//
//  ApplicationScanner+DirectoryScanning.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Application scanning helpers.
//

import MirageKit
#if os(macOS)
import CoreServices
import Foundation

// MARK: - Directory Scanning

extension ApplicationScanner {
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
            if domainPriority != other.domainPriority { return domainPriority > other.domainPriority }

            // Compare versions
            if let v1 = version, let v2 = other.version {
                let comparison = v1.compare(v2, options: .numeric)
                if comparison != .orderedSame { return comparison == .orderedDescending }
            }

            // Fallback to path comparison
            return path.localizedCaseInsensitiveCompare(other.path) == .orderedAscending
        }
    }

    func scanAllDirectories() async -> [AppCandidate] {
        if Task.isCancelled { return [] }
        return performDirectoryScan()
    }

    func performDirectoryScan() -> [AppCandidate] {
        var byBundle: [String: AppCandidate] = [:]
        var byPath: [String: AppCandidate] = [:]
        var seenPaths = Set<String>()

        for directory in scanDirectories {
            if Task.isCancelled { return Array(byBundle.values) + Array(byPath.values) }
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
                if Task.isCancelled { return Array(byBundle.values) + Array(byPath.values) }
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
        byPath _: inout [String: AppCandidate]
    )
    -> URL? {
        guard shouldConsiderApp(at: url, allowBundleContents: allowBundleContents) else { return nil }

        let canonicalURL = canonicalURL(forPath: url.path)
        guard seenPaths.insert(canonicalURL.path).inserted else { return nil }

        guard let candidate = candidateFromBundle(at: canonicalURL) else { return canonicalURL }

        // Skip apps without bundle identifiers (can't stream them reliably)
        guard let identifier = candidate.bundleIdentifier?.lowercased(), !identifier.isEmpty else { return canonicalURL }

        // Deduplicate by bundle identifier
        if let existing = byBundle[identifier] {
            if candidate.isPreferred(over: existing) { byBundle[identifier] = candidate }
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
        if Task.isCancelled { return }
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
            if Task.isCancelled { return }
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

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else { continue }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) { continue }

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
        if Task.isCancelled { return }
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
            if Task.isCancelled { return }
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

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else { continue }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) { continue }

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
        if bundle.bundleIdentifier == "com.ethanlipnik.Mirage" { return nil }

        let bundleID = bundle.bundleIdentifier ?? ""
        let isCoreServices = url.path.hasPrefix("/System/Library/CoreServices")

        // For CoreServices apps, use allowlist/blocklist filtering
        if isCoreServices {
            let lowercasedID = bundleID.lowercased()

            // Always include apps on the allowlist
            let isAllowlisted = coreServicesAllowlist.contains(lowercasedID)

            // Exclude apps matching system service patterns
            let matchesExclusionPattern = excludedBundlePatterns.contains { pattern in
                bundleID.contains(pattern)
            }

            // Skip if not allowlisted and matches exclusion pattern
            if !isAllowlisted, matchesExclusionPattern { return nil }

            // Also skip apps with no UI (background-only apps)
            if !isAllowlisted {
                let isBackgroundOnly = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
                    || bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true
                if isBackgroundOnly { return nil }
            }
        }

        var displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        if displayName?.isEmpty ?? true { displayName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String }
        if displayName?.isEmpty ?? true { displayName = url.deletingPathExtension().lastPathComponent }

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

    /// Compares two version strings using system version comparison
    func compareVersions(_ version1: String?, _ version2: String?) -> ComparisonResult? {
        guard let v1 = version1, let v2 = version2 else { return nil }
        return v1.compare(v2, options: .numeric)
    }
}

#endif
