//
//  MirageHostService+StreamCaptureSource.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation
import ScreenCaptureKit

#if os(macOS)

@MainActor
extension MirageHostService {
    /// ScreenCaptureKit source objects resolved for a requested Mirage window.
    struct StreamCaptureSource {
        /// CaptureKit window backing the stream.
        let window: SCWindow
        /// CaptureKit application that owns the window.
        let application: SCRunningApplication
        /// Display containing the window capture source.
        let display: SCDisplay
    }

    /// Refreshes capture content through the platform backend.
    func currentCaptureShareableContent() async throws -> SCShareableContent {
        let contentWrapper = try await platformCaptureContentProviderBackend.shareableContent()
        return contentWrapper.content
    }

    /// Resolves the CaptureKit source for a requested window, optionally remapping to a fallback.
    func resolveCaptureSource(
        for requestedWindow: MirageMedia.MirageWindow,
        from content: SCShareableContent,
        disallowedWindowIDs: Set<WindowID> = [],
        allowFallbackRemap: Bool = true
    ) throws -> StreamCaptureSource {
        if let directWindow = content.windows.first(where: { $0.windowID == requestedWindow.id }),
           !disallowedWindowIDs.contains(WindowID(directWindow.windowID)),
           let directApp = directWindow.owningApplication,
           let directDisplay = resolveDisplayForCaptureWindow(directWindow, displays: content.displays) {
            return StreamCaptureSource(window: directWindow, application: directApp, display: directDisplay)
        }

        guard allowFallbackRemap else {
            throw MirageCore.MirageError.windowNotFound
        }

        let requestedBundleID = requestedWindow.application?.bundleIdentifier?.lowercased()
        let requestedPID = requestedWindow.application?.id
        let fallbackCandidates = content.windows
            .filter { candidate in
                if disallowedWindowIDs.contains(WindowID(candidate.windowID)) {
                    return false
                }
                guard let candidateApp = candidate.owningApplication else { return false }
                if let requestedPID, candidateApp.processID == requestedPID { return true }
                guard let requestedBundleID else { return false }
                return candidateApp.bundleIdentifier.lowercased() == requestedBundleID
            }
            .sorted { lhs, rhs in
                AppWindowBindingPlanner.captureCandidateScore(
                    candidateIsOnScreen: lhs.isOnScreen,
                    candidateWindowLayer: Int(lhs.windowLayer),
                    candidateTitle: lhs.title,
                    candidateFrame: lhs.frame,
                    requestedWindowLayer: requestedWindow.windowLayer,
                    requestedTitle: requestedWindow.title,
                    requestedFrame: requestedWindow.frame
                ) <
                    AppWindowBindingPlanner.captureCandidateScore(
                        candidateIsOnScreen: rhs.isOnScreen,
                        candidateWindowLayer: Int(rhs.windowLayer),
                        candidateTitle: rhs.title,
                        candidateFrame: rhs.frame,
                        requestedWindowLayer: requestedWindow.windowLayer,
                        requestedTitle: requestedWindow.title,
                        requestedFrame: requestedWindow.frame
                    )
            }

        for candidate in fallbackCandidates {
            guard let candidateApp = candidate.owningApplication,
                  let candidateDisplay = resolveDisplayForCaptureWindow(candidate, displays: content.displays) else {
                continue
            }
            return StreamCaptureSource(window: candidate, application: candidateApp, display: candidateDisplay)
        }

        throw MirageCore.MirageError.windowNotFound
    }

    /// Chooses the display that contains or best overlaps a capture window.
    private func resolveDisplayForCaptureWindow(_ window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return containingDisplay
        }

        var bestIntersectionArea: CGFloat = 0
        var bestDisplay: SCDisplay?
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }
        if let bestDisplay { return bestDisplay }

        return displays.first
    }
}

#endif
