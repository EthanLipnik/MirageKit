//
//  ApplicationScanner+Candidates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

extension ApplicationScanner {
    /// Normalized metadata for a discovered app bundle before icon/status enrichment.
    struct AppCandidate: Hashable {
        let name: String
        let bundleIdentifier: String?
        let version: String?
        let url: URL
        let path: String
        let domainPriority: Int

        /// Returns whether this candidate should replace another candidate for the same bundle identifier.
        func isPreferred(over other: AppCandidate) -> Bool {
            guard self != other else { return false }

            // Higher domain priority wins.
            if domainPriority != other.domainPriority { return domainPriority > other.domainPriority }

            if let v1 = version, let v2 = other.version {
                let comparison = v1.compare(v2, options: .numeric)
                if comparison != .orderedSame { return comparison == .orderedDescending }
            }

            return path.localizedCaseInsensitiveCompare(other.path) == .orderedAscending
        }
    }

    /// Result from processing a candidate URL, including the canonical location for nested scans.
    struct ProcessCandidateResult {
        let canonicalURL: URL
        let preferredCandidate: AppCandidate?
    }

    /// Returns whether a new candidate is preferred over the current candidate for a bundle identifier.
    func shouldPrefer(
        _ candidate: AppCandidate,
        over existing: AppCandidate,
        bundleIdentifier: String,
        runningAppPathsByBundle: [String: Set<String>],
        defaultAppPathByBundleIdentifier: inout [String: String],
        missingDefaultAppPathBundleIdentifiers: inout Set<String>
    )
    -> Bool {
        let runningPaths = runningAppPathsByBundle[bundleIdentifier] ?? []
        let defaultPath = defaultAppPath(
            forBundleIdentifier: bundleIdentifier,
            cachedPaths: &defaultAppPathByBundleIdentifier,
            missingBundleIdentifiers: &missingDefaultAppPathBundleIdentifiers
        )
        if let runtimePreferred = Self.runtimePathPreference(
            candidatePath: candidate.path,
            existingPath: existing.path,
            runningPaths: runningPaths,
            defaultPath: defaultPath
        ) {
            return runtimePreferred
        }

        return candidate.isPreferred(over: existing)
    }

    /// Prefers the running or Launch Services default path when comparing duplicate bundle identifiers.
    nonisolated static func runtimePathPreference(
        candidatePath: String,
        existingPath: String,
        runningPaths: Set<String>,
        defaultPath: String?
    )
    -> Bool? {
        let candidateIsRunning = runningPaths.contains(candidatePath)
        let existingIsRunning = runningPaths.contains(existingPath)
        if candidateIsRunning != existingIsRunning { return candidateIsRunning }

        guard let defaultPath else { return nil }
        let candidateIsDefault = candidatePath == defaultPath
        let existingIsDefault = existingPath == defaultPath
        if candidateIsDefault != existingIsDefault { return candidateIsDefault }
        return nil
    }

    /// Builds an app candidate from a bundle URL after applying host and CoreServices filtering.
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

        // Skip the hosting app itself to avoid self-stream recursion.
        if let hostingBundleIdentifier = Bundle.main.bundleIdentifier,
           bundle.bundleIdentifier == hostingBundleIdentifier {
            return nil
        }

        let bundleID = bundle.bundleIdentifier ?? ""
        let isCoreServices = url.path.hasPrefix("/System/Library/CoreServices")

        if isCoreServices {
            let lowercasedID = bundleID.lowercased()
            let isAllowlisted = coreServicesAllowlist.contains(lowercasedID)
            let matchesExclusionPattern = excludedBundlePatterns.contains { pattern in
                bundleID.contains(pattern)
            }

            if !isAllowlisted, matchesExclusionPattern { return nil }

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
}
#endif
