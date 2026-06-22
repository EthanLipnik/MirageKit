//
//  AppStreamWindowCatalog+Discovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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
import CoreGraphics

#if os(macOS)
import AppKit
import ScreenCaptureKit

extension AppStreamWindowCatalog {
    /// Collapses native tab groups so only the visible representative remains.
    static func collapseTabGroups(
        _ candidates: [AppStreamWindowCandidate],
        metadata: [CGWindowID: WindowListMetadata]
    ) -> [AppStreamWindowCandidate] {
        let candidatesByProcessID = Dictionary(grouping: candidates) { candidate in
            candidate.window.application?.id ?? 0
        }

        var collapsedCandidates: [AppStreamWindowCandidate] = []
        for (_, processCandidates) in candidatesByProcessID {
            if processCandidates.count == 1, let candidate = processCandidates.first {
                collapsedCandidates.append(candidate)
                continue
            }

            var processedWindowIDs = Set<WindowID>()
            for candidate in processCandidates.sorted(by: preferredOrder(lhs:rhs:)) {
                guard !processedWindowIDs.contains(candidate.window.id) else { continue }

                let tabGroup = processCandidates.filter { other in
                    guard !processedWindowIDs.contains(other.window.id) else { return false }
                    return framesAreNearlyIdentical(candidate.window.frame, other.window.frame)
                }
                guard !tabGroup.isEmpty else { continue }

                let representative = tabGroup.min { lhs, rhs in
                    let lhsOnScreen = metadata[CGWindowID(lhs.window.id)]?.isOnScreen ?? lhs.window.isOnScreen
                    let rhsOnScreen = metadata[CGWindowID(rhs.window.id)]?.isOnScreen ?? rhs.window.isOnScreen
                    if lhsOnScreen != rhsOnScreen { return lhsOnScreen }
                    if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                    if lhs.isMain != rhs.isMain { return lhs.isMain }
                    return preferredOrder(lhs: lhs, rhs: rhs)
                }
                    ?? candidate

                collapsedCandidates.append(representative)
                processedWindowIDs.formUnion(tabGroup.map(\.window.id))
            }
        }

        let onScreenCandidates = collapsedCandidates.filter { candidate in
            metadata[CGWindowID(candidate.window.id)]?.isOnScreen ?? candidate.window.isOnScreen
        }
        if !onScreenCandidates.isEmpty {
            return onScreenCandidates
        }
        return collapsedCandidates
    }

    /// Resolves the requested bundle identifier represented by an SCK application.
    static func matchedBundleIdentifier(
        for app: SCRunningApplication,
        normalizedBundleIDs: Set<String>,
        runningPIDsByBundleID: [String: Set<pid_t>]
    ) -> String? {
        let ownerBundleID = app.bundleIdentifier.lowercased()
        if normalizedBundleIDs.contains(ownerBundleID) {
            return ownerBundleID
        }

        let ownerPID = app.processID
        return runningPIDsByBundleID.first { entry in
            entry.value.contains(ownerPID)
        }?.key
    }

    /// Returns running process IDs for requested bundle identifiers.
    static func runningProcessIDs(for normalizedBundleIDs: Set<String>) -> [String: Set<pid_t>] {
        var result: [String: Set<pid_t>] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier?.lowercased(),
                  normalizedBundleIDs.contains(bundleIdentifier) else { continue }
            result[bundleIdentifier, default: []].insert(app.processIdentifier)
        }
        return result
    }
}
#endif
