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

struct ResolvedAppWindowBinding: Sendable {
    let candidate: AppStreamWindowCandidate
    let resolvedWindow: MirageWindow
}

struct AppWindowBindingPlan: Sendable {
    let resolvedBindings: [ResolvedAppWindowBinding]
    let unresolvedCandidates: [AppStreamWindowCandidate]
}

enum AppWindowBindingPlanner {
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
            } else {
                let sorted = compatible.sorted { lhs, rhs in
                    captureCandidateScore(lhs, requestedWindow: candidate.window) <
                        captureCandidateScore(rhs, requestedWindow: candidate.window)
                }
                guard let best = sorted.first else {
                    unresolvedCandidates.append(candidate)
                    continue
                }
                resolvedWindow = best
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

    static func captureCandidateScore(
        _ candidate: MirageWindow,
        requestedWindow: MirageWindow
    ) -> Int {
        var score = 0

        if !candidate.isOnScreen {
            score += 1_000_000
        }

        if candidate.windowLayer != 0 {
            score += 2_000
        }
        score += abs(candidate.windowLayer - requestedWindow.windowLayer) * 250

        let requestedTitle = (requestedWindow.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateTitle = (candidate.title ?? "")
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

        let requestedFrame = requestedWindow.frame
        let candidateFrame = candidate.frame
        let sizeDelta = abs(candidateFrame.width - requestedFrame.width) +
            abs(candidateFrame.height - requestedFrame.height)
        let originDelta = abs(candidateFrame.minX - requestedFrame.minX) +
            abs(candidateFrame.minY - requestedFrame.minY)
        score += Int(sizeDelta)
        score += Int(originDelta * 0.25)

        if candidateFrame.width < 160 || candidateFrame.height < 120 {
            score += 10_000
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
