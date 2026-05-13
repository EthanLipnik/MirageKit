//
//  AppStreamWindowCatalog.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Shared app-stream window cataloging and classification helpers.
//

import MirageKit
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

enum AppStreamWindowClassification: String {
    case primary
    case auxiliary
}

/// Window candidate with ScreenCaptureKit and Accessibility classification metadata.
struct AppStreamWindowCandidate {
    let window: MirageWindow
    let classification: AppStreamWindowClassification
    let role: String?
    let subrole: String?
    let parentWindowID: WindowID?
    let isFocused: Bool
    let isMain: Bool
    let isModal: Bool
    let windowListOrder: Int

    init(
        window: MirageWindow,
        classification: AppStreamWindowClassification,
        role: String?,
        subrole: String?,
        parentWindowID: WindowID?,
        isFocused: Bool = false,
        isMain: Bool = false,
        isModal: Bool = false,
        windowListOrder: Int = Int.max
    ) {
        self.window = window
        self.classification = classification
        self.role = role
        self.subrole = subrole
        self.parentWindowID = parentWindowID
        self.isFocused = isFocused
        self.isMain = isMain
        self.isModal = isModal
        self.windowListOrder = windowListOrder
    }

    /// Metadata summary used in startup and retry diagnostics.
    var logMetadata: String {
        "classification=\(classification.rawValue), focused=\(isFocused), main=\(isMain), modal=\(isModal), role=\(role ?? "nil"), subrole=\(subrole ?? "nil"), parent=\(parentWindowID.map(String.init) ?? "nil")"
    }
}

/// Ordered set of windows captured together for an app stream.
struct AppStreamCapturedWindowCluster: Equatable {
    let windowIDs: [WindowID]
}

/// Builds and filters app-stream window candidates from ScreenCaptureKit and Accessibility.
enum AppStreamWindowCatalog {
    /// Accessibility-derived classification attributes for a host window.
    struct AccessibilityClassification {
        let role: String?
        let subrole: String?
        let parentWindowID: WindowID?
        let isFocused: Bool
        let isMain: Bool
        let isModal: Bool
    }

    static let minimumAuxiliaryWindowSize = CGSize(width: 24, height: 24)
    static let minimumVisibleAlpha: CGFloat = 0.05

    /// Returns app-stream candidates grouped by normalized bundle identifier.
    static func catalog(
        for bundleIdentifiers: [String],
        minimumWindowSize: CGSize = CGSize(width: 160, height: 120)
    )
    async throws -> [String: [AppStreamWindowCandidate]] {
        let normalizedBundleIDs = Set(bundleIdentifiers.map { $0.lowercased() })
        guard !normalizedBundleIDs.isEmpty else { return [:] }

        let runningPIDsByBundleID = runningProcessIDs(for: normalizedBundleIDs)
        let content = try await SCShareableContent.mirageHostContent()
        let windowMetadata = fetchWindowMetadata()

        var candidatesByBundleID: [String: [AppStreamWindowCandidate]] = [:]
        var accessibilityByProcessID: [pid_t: [WindowID: AccessibilityClassification]] = [:]

        for window in content.windows {
            guard let app = window.owningApplication else { continue }

            guard let matchedBundleID = matchedBundleIdentifier(
                for: app,
                normalizedBundleIDs: normalizedBundleIDs,
                runningPIDsByBundleID: runningPIDsByBundleID
            ) else { continue }

            let appModel = MirageApplication(
                id: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                name: app.applicationName,
                iconData: nil
            )
            let normalizedWindow = MirageWindow(
                id: WindowID(window.windowID),
                title: window.title,
                application: appModel,
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                windowLayer: Int(window.windowLayer)
            )

            let processID = app.processID
            let perProcessAccessibility: [WindowID: AccessibilityClassification]
            if let cached = accessibilityByProcessID[processID] {
                perProcessAccessibility = cached
            } else {
                let indexed = buildAccessibilityIndex(processID: processID) ?? [:]
                accessibilityByProcessID[processID] = indexed
                perProcessAccessibility = indexed
            }
            let accessibility = perProcessAccessibility[normalizedWindow.id]
            let classification = classifyWindow(
                role: accessibility?.role,
                subrole: accessibility?.subrole,
                parentWindowID: accessibility?.parentWindowID,
                isFocused: accessibility?.isFocused ?? false,
                isMain: accessibility?.isMain ?? false,
                isModal: accessibility?.isModal ?? false
            )
            let metadata = windowMetadata[CGWindowID(window.windowID)]
            guard catalogEligibility(
                classification: classification,
                frame: window.frame,
                windowLayer: Int(window.windowLayer),
                screenCaptureIsOnScreen: window.isOnScreen,
                metadata: metadata,
                hasMatchingScreenCaptureWindow: true,
                minimumWindowSize: minimumWindowSize
            ) else { continue }

            let candidate = AppStreamWindowCandidate(
                window: normalizedWindow,
                classification: classification,
                role: accessibility?.role,
                subrole: accessibility?.subrole,
                parentWindowID: accessibility?.parentWindowID,
                isFocused: accessibility?.isFocused ?? false,
                isMain: accessibility?.isMain ?? false,
                isModal: accessibility?.isModal ?? false,
                windowListOrder: metadata?.orderIndex ?? Int.max
            )

            candidatesByBundleID[matchedBundleID, default: []].append(candidate)
        }

        for bundleID in candidatesByBundleID.keys {
            let collapsedCandidates = collapseTabGroups(
                candidatesByBundleID[bundleID] ?? [],
                metadata: windowMetadata
            )
            candidatesByBundleID[bundleID] = collapsedCandidates.sorted(by: preferredOrder(lhs:rhs:))
        }

        return candidatesByBundleID
    }

    /// Sorts startup candidates by user-visible priority.
    static func preferredOrder(lhs: AppStreamWindowCandidate, rhs: AppStreamWindowCandidate) -> Bool {
        if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        if lhs.isModal != rhs.isModal { return lhs.isModal }
        if lhs.window.isOnScreen != rhs.window.isOnScreen { return lhs.window.isOnScreen }
        if lhs.window.windowLayer != rhs.window.windowLayer { return lhs.window.windowLayer < rhs.window.windowLayer }
        if lhs.windowListOrder != rhs.windowListOrder { return lhs.windowListOrder < rhs.windowListOrder }

        let lhsArea = lhs.window.frame.width * lhs.window.frame.height
        let rhsArea = rhs.window.frame.width * rhs.window.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }

        return lhs.window.id < rhs.window.id
    }

    /// Selects strict primary candidates for initial app-stream startup.
    static func startupCandidateSelection(
        from candidates: [AppStreamWindowCandidate]
    ) -> [AppStreamWindowCandidate] {
        let sortedCandidates = candidates.sorted(by: preferredOrder(lhs:rhs:))
        return sortedCandidates.filter { $0.classification == .primary }
    }

    /// Returns the parent/child window cluster associated with a primary window.
    static func capturedWindowCluster(
        primaryWindowID: WindowID,
        candidates: [AppStreamWindowCandidate]
    ) -> AppStreamCapturedWindowCluster? {
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.window.id, $0) })
        guard let primaryCandidate = candidatesByID[primaryWindowID] else { return nil }

        let childrenByParent = Dictionary(grouping: candidates) { $0.parentWindowID }
        var visited = Set<WindowID>([primaryWindowID])
        var queue: [WindowID] = [primaryWindowID]
        var memberCandidates: [AppStreamWindowCandidate] = [primaryCandidate]

        while !queue.isEmpty {
            let nextParentID = queue.removeFirst()
            for childCandidate in childrenByParent[nextParentID] ?? [] {
                let childWindowID = childCandidate.window.id
                guard visited.insert(childWindowID).inserted else { continue }
                memberCandidates.append(childCandidate)
                queue.append(childWindowID)
            }
        }

        let orderedMembers = memberCandidates.sorted { lhs, rhs in
            if lhs.window.id == primaryWindowID { return true }
            if rhs.window.id == primaryWindowID { return false }
            return preferredOrder(lhs: lhs, rhs: rhs)
        }
        return AppStreamCapturedWindowCluster(
            windowIDs: orderedMembers.map(\.window.id)
        )
    }

    /// Classifies a host window as primary or auxiliary from Accessibility metadata.
    static func classifyWindow(
        role: String?,
        subrole: String?,
        parentWindowID: WindowID?,
        isFocused: Bool = false,
        isMain: Bool = false,
        isModal: Bool = false
    ) -> AppStreamWindowClassification {
        if parentWindowID != nil { return .auxiliary }

        let roleLower = role?.lowercased() ?? ""
        let subroleLower = subrole?.lowercased() ?? ""
        let hasActiveAuxiliaryState = isFocused || isMain || isModal

        if roleLower.contains("sheet") ||
            roleLower.contains("dialog") ||
            roleLower.contains("popover") ||
            roleLower.contains("drawer") ||
            roleLower.contains("system") ||
            roleLower.contains("floating") ||
            roleLower.contains("panel") {
            return .auxiliary
        }

        if subroleLower.contains("dialog") ||
            subroleLower.contains("popover") ||
            subroleLower.contains("drawer") ||
            subroleLower.contains("system") ||
            subroleLower.contains("floating") ||
            subroleLower.contains("utility") ||
            subroleLower.contains("panel") {
            return .auxiliary
        }

        if roleLower.contains("unknown") || subroleLower.contains("unknown"), hasActiveAuxiliaryState {
            return .auxiliary
        }

        return .primary
    }

    /// Returns whether a candidate window is eligible for app-stream cataloging.
    static func catalogEligibility(
        classification: AppStreamWindowClassification,
        frame: CGRect,
        windowLayer: Int,
        screenCaptureIsOnScreen: Bool,
        metadata: WindowListMetadata?,
        hasMatchingScreenCaptureWindow: Bool,
        minimumWindowSize: CGSize = CGSize(width: 160, height: 120)
    ) -> Bool {
        guard hasMatchingScreenCaptureWindow,
              isFiniteNonEmptyFrame(frame) else {
            return false
        }

        switch classification {
        case .primary:
            return windowLayer == 0 &&
                frame.width >= minimumWindowSize.width &&
                frame.height >= minimumWindowSize.height
        case .auxiliary:
            let visible = screenCaptureIsOnScreen || (metadata?.isOnScreen ?? false)
            let alpha = metadata?.alpha ?? 1
            return visible &&
                alpha > minimumVisibleAlpha &&
                frame.width >= minimumAuxiliaryWindowSize.width &&
                frame.height >= minimumAuxiliaryWindowSize.height
        }
    }

    /// Returns whether a frame is finite and non-empty.
    static func isFiniteNonEmptyFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.width > 0 &&
            frame.height > 0
    }

}

#endif
