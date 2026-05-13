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
import Foundation

// MARK: - Directory Scanning

extension ApplicationScanner {
    /// Scans configured application roots and reports each newly preferred candidate as it is discovered.
    func scanAllDirectories(
        onPreferredCandidate: (@Sendable (AppCandidate) async -> Void)? = nil
    ) async -> [AppCandidate] {
        if Task.isCancelled { return [] }
        return await performDirectoryScan(onPreferredCandidate: onPreferredCandidate)
    }

    /// Performs the full app directory scan and deduplicates candidates by bundle identifier.
    func performDirectoryScan(
        onPreferredCandidate: (@Sendable (AppCandidate) async -> Void)?
    ) async -> [AppCandidate] {
        var byBundle: [String: AppCandidate] = [:]
        var seenPaths = Set<String>()
        let runningAppPathsByBundle = runningAppPathsByBundleIdentifier()
        var defaultAppPathByBundleIdentifier: [String: String] = [:]
        var missingDefaultAppPathBundleIdentifiers = Set<String>()

        for directory in scanDirectories {
            if Task.isCancelled { return Array(byBundle.values) }
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    MirageLogger.host("Application scanner failed to enumerate \(url.path): \(error)")
                    return true
                }
            ) else {
                continue
            }

            for url in Self.urls(from: enumerator) {
                if Task.isCancelled { return Array(byBundle.values) }
                guard let result = processCandidate(
                    at: url,
                    allowBundleContents: false,
                    seenPaths: &seenPaths,
                    runningAppPathsByBundle: runningAppPathsByBundle,
                    defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                    missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                    byBundle: &byBundle
                ) else {
                    continue
                }
                if let preferredCandidate = result.preferredCandidate {
                    await onPreferredCandidate?(preferredCandidate)
                }

                // Check if we should scan inside this app bundle (e.g., Xcode)
                if allowsScanningBundleContents(at: result.canonicalURL) {
                    await scanNestedApps(
                        inside: result.canonicalURL,
                        currentDepth: 0,
                        maxDepth: nestedBundleScanDepth,
                        seenPaths: &seenPaths,
                        runningAppPathsByBundle: runningAppPathsByBundle,
                        defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                        missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                        byBundle: &byBundle,
                        onPreferredCandidate: onPreferredCandidate
                    )
                }
            }
        }

        return Array(byBundle.values)
    }

    /// Materializes URLs from a directory enumerator so iteration can stay actor-isolated.
    nonisolated private static func urls(from enumerator: FileManager.DirectoryEnumerator) -> [URL] {
        var urls: [URL] = []
        for case let url as URL in enumerator {
            urls.append(url)
        }
        return urls
    }

    /// Converts a filesystem URL into a candidate and updates the current preferred candidate map.
    func processCandidate(
        at url: URL,
        allowBundleContents: Bool,
        seenPaths: inout Set<String>,
        runningAppPathsByBundle: [String: Set<String>],
        defaultAppPathByBundleIdentifier: inout [String: String],
        missingDefaultAppPathBundleIdentifiers: inout Set<String>,
        byBundle: inout [String: AppCandidate]
    )
    -> ProcessCandidateResult? {
        guard shouldConsiderApp(at: url, allowBundleContents: allowBundleContents) else { return nil }

        let canonicalURL = canonicalURL(forPath: url.path)
        guard seenPaths.insert(canonicalURL.path).inserted else { return nil }

        guard let candidate = candidateFromBundle(at: canonicalURL) else {
            return ProcessCandidateResult(canonicalURL: canonicalURL, preferredCandidate: nil)
        }

        // Skip apps without bundle identifiers (can't stream them reliably)
        guard let identifier = candidate.bundleIdentifier?.lowercased(), !identifier.isEmpty else {
            return ProcessCandidateResult(canonicalURL: canonicalURL, preferredCandidate: nil)
        }

        // Deduplicate by bundle identifier
        var preferredCandidate: AppCandidate?
        if let existing = byBundle[identifier] {
            if shouldPrefer(
                candidate,
                over: existing,
                bundleIdentifier: identifier,
                runningAppPathsByBundle: runningAppPathsByBundle,
                defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers
            ) {
                byBundle[identifier] = candidate
                preferredCandidate = candidate
            }
        } else {
            byBundle[identifier] = candidate
            preferredCandidate = candidate
        }

        return ProcessCandidateResult(canonicalURL: canonicalURL, preferredCandidate: preferredCandidate)
    }

    /// Recursively scans bundle contents when a top-level app is allowed to expose nested apps.
    func scanNestedApps(
        inside directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        seenPaths: inout Set<String>,
        runningAppPathsByBundle: [String: Set<String>],
        defaultAppPathByBundleIdentifier: inout [String: String],
        missingDefaultAppPathBundleIdentifiers: inout Set<String>,
        byBundle: inout [String: AppCandidate],
        onPreferredCandidate: (@Sendable (AppCandidate) async -> Void)?
    ) async {
        if Task.isCancelled { return }
        guard currentDepth < maxDepth else { return }

        let lowercasedPath = directory.path.lowercased()
        if lowercasedPath.contains(".simruntime") ||
            lowercasedPath.contains("coresimulator") ||
            lowercasedPath.contains("runtimeroot") {
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            MirageLogger.debug(.host, "Skipping unreadable application scan directory \(directory.path): \(error)")
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

                if let result = processCandidate(
                    at: entry,
                    allowBundleContents: true,
                    seenPaths: &seenPaths,
                    runningAppPathsByBundle: runningAppPathsByBundle,
                    defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                    missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                    byBundle: &byBundle
                ) {
                    if let preferredCandidate = result.preferredCandidate {
                        await onPreferredCandidate?(preferredCandidate)
                    }
                    if nextDepth < maxDepth {
                        await scanNestedApps(
                            inside: result.canonicalURL,
                            currentDepth: nextDepth,
                            maxDepth: maxDepth,
                            seenPaths: &seenPaths,
                            runningAppPathsByBundle: runningAppPathsByBundle,
                            defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                            missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                            byBundle: &byBundle,
                            onPreferredCandidate: onPreferredCandidate
                        )
                    }
                }
                continue
            }

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else { continue }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) { continue }

            // Check for Applications/Utilities subdirectories
            if lowercasedName.contains("applications") || lowercasedName.contains("utilities") {
                await collectApplications(
                    inside: entry,
                    currentDepth: nextDepth,
                    maxDepth: maxDepth,
                    seenPaths: &seenPaths,
                    runningAppPathsByBundle: runningAppPathsByBundle,
                    defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                    missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                    byBundle: &byBundle,
                    onPreferredCandidate: onPreferredCandidate
                )
                continue
            }

            // Descend through transit directories
            if shouldDescendThroughTransitDirectory(named: lowercasedName) {
                await scanNestedApps(
                    inside: entry,
                    currentDepth: nextDepth,
                    maxDepth: maxDepth,
                    seenPaths: &seenPaths,
                    runningAppPathsByBundle: runningAppPathsByBundle,
                    defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                    missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                    byBundle: &byBundle,
                    onPreferredCandidate: onPreferredCandidate
                )
            }
        }
    }

    /// Recursively collects app bundles below an Applications or Utilities directory.
    func collectApplications(
        inside directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        seenPaths: inout Set<String>,
        runningAppPathsByBundle: [String: Set<String>],
        defaultAppPathByBundleIdentifier: inout [String: String],
        missingDefaultAppPathBundleIdentifiers: inout Set<String>,
        byBundle: inout [String: AppCandidate],
        onPreferredCandidate: (@Sendable (AppCandidate) async -> Void)?
    ) async {
        if Task.isCancelled { return }
        guard currentDepth < maxDepth else { return }

        let lowercasedPath = directory.path.lowercased()
        if lowercasedPath.contains(".simruntime") ||
            lowercasedPath.contains("coresimulator") ||
            lowercasedPath.contains("runtimeroot") {
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            MirageLogger.debug(.host, "Skipping unreadable catalog scan directory \(directory.path): \(error)")
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

                if let result = processCandidate(
                    at: entry,
                    allowBundleContents: true,
                    seenPaths: &seenPaths,
                    runningAppPathsByBundle: runningAppPathsByBundle,
                    defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                    missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                    byBundle: &byBundle
                ) {
                    if let preferredCandidate = result.preferredCandidate {
                        await onPreferredCandidate?(preferredCandidate)
                    }
                    if nextDepth < maxDepth {
                        await scanNestedApps(
                            inside: result.canonicalURL,
                            currentDepth: nextDepth,
                            maxDepth: maxDepth,
                            seenPaths: &seenPaths,
                            runningAppPathsByBundle: runningAppPathsByBundle,
                            defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                            missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                            byBundle: &byBundle,
                            onPreferredCandidate: onPreferredCandidate
                        )
                    }
                }
                continue
            }

            guard let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }

            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else { continue }

            if shouldIgnoreNestedDirectory(named: entry.lastPathComponent) { continue }

            // Continue collecting in subdirectories
            await collectApplications(
                inside: entry,
                currentDepth: nextDepth,
                maxDepth: maxDepth,
                seenPaths: &seenPaths,
                runningAppPathsByBundle: runningAppPathsByBundle,
                defaultAppPathByBundleIdentifier: &defaultAppPathByBundleIdentifier,
                missingDefaultAppPathBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers,
                byBundle: &byBundle,
                onPreferredCandidate: onPreferredCandidate
            )
        }
    }

}

#endif
