//
//  DesktopStreamStartAcceptanceDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start acceptance decisions.
//

import MirageKit

enum DesktopStreamStartAcceptanceDecision: Equatable {
    case accept
    case acceptResizeAdvance
    case ignoreDuplicateToken
    case ignoreOlderToken
    case ignoreMissingTokenAfterTokenizedStart

    var shouldAccept: Bool {
        switch self {
        case .accept,
             .acceptResizeAdvance:
            true
        case .ignoreDuplicateToken,
             .ignoreOlderToken,
             .ignoreMissingTokenAfterTokenizedStart:
            false
        }
    }

    func rejectionReasonText(
        previousDimensionToken: UInt16?,
        receivedDimensionToken: UInt16?
    ) -> String {
        let tokenText = receivedDimensionToken.map(String.init) ?? "nil"
        let previousTokenText = previousDimensionToken.map(String.init) ?? "nil"
        return switch self {
        case .ignoreDuplicateToken:
            "duplicate dimension token \(tokenText)"
        case .ignoreOlderToken:
            "older dimension token \(tokenText) < \(previousTokenText)"
        case .ignoreMissingTokenAfterTokenizedStart:
            "missing dimension token after prior token \(previousTokenText)"
        case .accept,
             .acceptResizeAdvance:
            "accepted"
        }
    }
}

func desktopStreamStartAcceptanceDecision(
    streamID: StreamID,
    previousStreamID: StreamID?,
    hasController: Bool,
    requestStartPending: Bool,
    previousDimensionToken: UInt16?,
    receivedDimensionToken: UInt16?
)
-> DesktopStreamStartAcceptanceDecision {
    if requestStartPending { return .accept }
    if previousStreamID == nil || previousStreamID != streamID { return .accept }
    if !hasController { return .accept }
    guard let previousDimensionToken else { return .accept }
    guard let receivedDimensionToken else {
        return .ignoreMissingTokenAfterTokenizedStart
    }
    if receivedDimensionToken < previousDimensionToken {
        return .ignoreOlderToken
    }
    if receivedDimensionToken == previousDimensionToken {
        return .ignoreDuplicateToken
    }
    return .acceptResizeAdvance
}
