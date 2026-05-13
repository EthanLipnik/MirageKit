//
//  MirageHostService+AppLifecycleCandidates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Classification outcome for a newly detected app window candidate.
    enum AppLifecycleCandidateDisposition: String, Equatable {
        case eligible
        case auxiliary
        case visibleStreamBound
        case claimedByActiveStream
    }

    /// Classifies whether a detected app window can enter hidden inventory or should be ignored.
    nonisolated static func appLifecycleCandidateDisposition(
        candidate: AppStreamWindowCandidate,
        visibleWindowIDs: Set<WindowID>,
        claimedWindowIDs: Set<WindowID>
    ) -> AppLifecycleCandidateDisposition {
        guard candidate.classification == .primary else { return .auxiliary }
        if visibleWindowIDs.contains(candidate.window.id) {
            return .visibleStreamBound
        }
        if claimedWindowIDs.contains(candidate.window.id) {
            return .claimedByActiveStream
        }
        return .eligible
    }

    /// Returns the host log text for a candidate classification outcome.
    nonisolated static func appLifecycleCandidateDispositionReason(
        _ disposition: AppLifecycleCandidateDisposition
    ) -> String {
        switch disposition {
        case .eligible:
            "eligible"
        case .auxiliary:
            "auxiliary child window"
        case .visibleStreamBound:
            "already bound to a visible stream"
        case .claimedByActiveStream:
            "claimed by an active stream owner"
        }
    }
}

#endif
