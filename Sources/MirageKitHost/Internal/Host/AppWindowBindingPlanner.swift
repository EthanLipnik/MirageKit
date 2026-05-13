//
//  AppWindowBindingPlanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Deterministic one-to-one app-window binding for multi-window startup.
//

import MirageKit

#if os(macOS)
import Foundation

/// Pairing between a requested app-window candidate and the live host window selected for capture.
struct ResolvedAppWindowBinding {
    /// Client-requested candidate that needs an app stream.
    let candidate: AppStreamWindowCandidate
    /// Current host window that should back the requested stream.
    let resolvedWindow: MirageWindow
}

/// Result of matching requested app-window streams against the host's current window inventory.
struct AppWindowBindingPlan {
    /// Candidates that can be backed by live windows immediately.
    let resolvedBindings: [ResolvedAppWindowBinding]
    /// Candidates that need the normal launch/retry path before a stream can start.
    let unresolvedCandidates: [AppStreamWindowCandidate]
}

/// Builds deterministic one-to-one bindings from requested app streams to live app windows.
enum AppWindowBindingPlanner {
    /// Matches each candidate to an unclaimed live window from the same process or bundle.
    static func plan(
        candidates: [AppStreamWindowCandidate],
        liveWindows: [MirageWindow],
        claimedWindowIDs: Set<WindowID>
    ) -> AppWindowBindingPlan {
        var claimed = claimedWindowIDs
        var resolvedBindings: [ResolvedAppWindowBinding] = []
        var unresolvedCandidates: [AppStreamWindowCandidate] = []
        resolvedBindings.reserveCapacity(candidates.count)
        unresolvedCandidates.reserveCapacity(candidates.count)

        for candidate in candidates {
            let compatible = compatibleLiveWindows(
                for: candidate.window,
                from: liveWindows,
                claimedWindowIDs: claimed
            )

            guard !compatible.isEmpty else {
                unresolvedCandidates.append(candidate)
                continue
            }

            let resolvedWindow: MirageWindow
            if let direct = compatible.first(where: { $0.id == candidate.window.id }) {
                resolvedWindow = direct
            } else if let bestCompatibleWindow = compatible.min(by: { lhs, rhs in
                captureCandidateScore(lhs, requestedWindow: candidate.window) <
                    captureCandidateScore(rhs, requestedWindow: candidate.window)
            }) {
                resolvedWindow = bestCompatibleWindow
            } else {
                unresolvedCandidates.append(candidate)
                continue
            }

            claimed.insert(resolvedWindow.id)
            resolvedBindings.append(
                ResolvedAppWindowBinding(
                    candidate: candidate,
                    resolvedWindow: resolvedWindow
                )
            )
        }

        return AppWindowBindingPlan(
            resolvedBindings: resolvedBindings,
            unresolvedCandidates: unresolvedCandidates
        )
    }

    /// Scores lower for windows that look more like the requested candidate.
    static func captureCandidateScore(
        _ candidate: MirageWindow,
        requestedWindow: MirageWindow
    ) -> Int {
        captureCandidateScore(
            candidateIsOnScreen: candidate.isOnScreen,
            candidateWindowLayer: candidate.windowLayer,
            candidateTitle: candidate.title,
            candidateFrame: candidate.frame,
            requestedWindowLayer: requestedWindow.windowLayer,
            requestedTitle: requestedWindow.title,
            requestedFrame: requestedWindow.frame
        )
    }

    /// Scores lower for raw window attributes that better match the requested window.
    static func captureCandidateScore(
        candidateIsOnScreen: Bool,
        candidateWindowLayer: Int,
        candidateTitle: String?,
        candidateFrame: CGRect,
        requestedWindowLayer: Int,
        requestedTitle: String?,
        requestedFrame: CGRect
    ) -> Int {
        var score = 0

        if !candidateIsOnScreen {
            score += 1_000_000
        }

        if candidateWindowLayer != 0 {
            score += 2000
        }
        score += abs(candidateWindowLayer - requestedWindowLayer) * 250

        let requestedTitle = (requestedTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateTitle = (candidateTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !requestedTitle.isEmpty {
            if candidateTitle == requestedTitle {
                score += 0
            } else if candidateTitle.contains(requestedTitle) || requestedTitle.contains(candidateTitle) {
                score += 150
            } else {
                score += 600
            }
        }

        let sizeDelta = abs(candidateFrame.width - requestedFrame.width) +
            abs(candidateFrame.height - requestedFrame.height)
        let originDelta = abs(candidateFrame.minX - requestedFrame.minX) +
            abs(candidateFrame.minY - requestedFrame.minY)
        score += Int(sizeDelta)
        score += Int(originDelta * 0.25)

        if candidateFrame.width < 160 || candidateFrame.height < 120 {
            score += 10000
        }

        return score
    }

    private static func compatibleLiveWindows(
        for requestedWindow: MirageWindow,
        from liveWindows: [MirageWindow],
        claimedWindowIDs: Set<WindowID>
    ) -> [MirageWindow] {
        let requestedBundleID = requestedWindow.application?.bundleIdentifier?.lowercased()
        let requestedPID = requestedWindow.application?.id
        return liveWindows.filter { candidate in
            guard !claimedWindowIDs.contains(candidate.id) else { return false }
            guard let candidateApp = candidate.application else { return false }
            if let requestedPID, candidateApp.id == requestedPID { return true }
            guard let requestedBundleID else { return false }
            return candidateApp.bundleIdentifier?.lowercased() == requestedBundleID
        }
    }
}

#endif
