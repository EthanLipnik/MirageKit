//
//  MirageHostService+AuxiliaryWindowParenting.swift
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
import CoreGraphics

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Resolves the visible parent stream that should receive an auxiliary app window.
    func resolveParentStreamIDForAuxiliaryWindow(
        bundleIdentifier: String,
        candidate: AppStreamWindowCandidate,
        session: MirageAppStreamSession
    ) async -> StreamID? {
        if let parentWindowID = candidate.parentWindowID {
            let streamIDForClusterParent = await appStreamManager.streamIDForCapturedClusterWindow(
                bundleIdentifier: bundleIdentifier,
                windowID: parentWindowID
            )
            let directParentStreamID = await appStreamManager.streamIDForWindow(
                bundleIdentifier: bundleIdentifier,
                windowID: parentWindowID
            )
            if let streamID = streamIDForClusterParent ?? directParentStreamID {
                return streamID
            }
        }

        let visibleStreamIDs = Set(session.windowStreams.values.map(\.streamID))
        if candidate.isFocused || candidate.isMain || candidate.isModal {
            let activeStreams = await appStreamManager.streamActivityMap(bundleIdentifier: bundleIdentifier)
            if let activeStreamID = Self.preferredActiveVisibleStreamID(
                activeStreams: activeStreams,
                visibleStreamIDs: visibleStreamIDs
            ) {
                return activeStreamID
            }
        }

        let visibleParentCandidates = session.windowStreams.values.compactMap { info -> (streamID: StreamID, frame: CGRect)? in
            guard let activeSession = activeSessionByStreamID[info.streamID] else { return nil }
            return (
                streamID: info.streamID,
                frame: currentWindowFrame(for: activeSession.window.id) ?? activeSession.window.frame
            )
        }
        return Self.bestAuxiliaryParentStream(
            auxiliaryFrame: candidate.window.frame,
            visibleParents: visibleParentCandidates
        )
    }

    /// Selects the stable parent stream for focused, main, or modal auxiliary windows.
    nonisolated static func preferredActiveVisibleStreamID(
        activeStreams: [StreamID: Bool],
        visibleStreamIDs: Set<StreamID>
    ) -> StreamID? {
        activeStreams
            .filter { entry in entry.value && visibleStreamIDs.contains(entry.key) }
            .map(\.key)
            .min()
    }

    /// Chooses the nearest visible stream by overlap first, then center distance.
    nonisolated static func bestAuxiliaryParentStream(
        auxiliaryFrame: CGRect,
        visibleParents: [(streamID: StreamID, frame: CGRect)]
    ) -> StreamID? {
        guard !visibleParents.isEmpty else { return nil }
        let auxiliaryCenter = CGPoint(x: auxiliaryFrame.midX, y: auxiliaryFrame.midY)
        return visibleParents.min { lhs, rhs in
            let lhsOverlap = overlapArea(lhs.frame, auxiliaryFrame)
            let rhsOverlap = overlapArea(rhs.frame, auxiliaryFrame)
            if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }

            let lhsDistance = squaredDistance(from: auxiliaryCenter, to: CGPoint(x: lhs.frame.midX, y: lhs.frame.midY))
            let rhsDistance = squaredDistance(from: auxiliaryCenter, to: CGPoint(x: rhs.frame.midX, y: rhs.frame.midY))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.streamID < rhs.streamID
        }?.streamID
    }

    private nonisolated static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return (dx * dx) + (dy * dy)
    }
}

#endif
