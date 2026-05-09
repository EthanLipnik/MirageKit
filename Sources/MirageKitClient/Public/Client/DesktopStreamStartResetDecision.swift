//
//  DesktopStreamStartResetDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start reset decisions.
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

enum DesktopStreamStartResetDecision: Equatable {
    case resetController
    case reuseController
}

func desktopStreamStartResetDecision(
    streamID: StreamID,
    previousStreamID: StreamID?,
    hasController: Bool,
    requestStartPending: Bool,
    previousDimensionToken: UInt16?,
    receivedDimensionToken: UInt16?
)
-> DesktopStreamStartResetDecision {
    if requestStartPending { return .resetController }
    if previousStreamID == nil || previousStreamID != streamID { return .resetController }
    if !hasController { return .resetController }

    if let previousDimensionToken, let receivedDimensionToken, previousDimensionToken != receivedDimensionToken {
        return .resetController
    }

    return .reuseController
}

func desktopStreamStartGeometryChanged(
    previousDisplaySize: CGSize?,
    previousPresentationSize: CGSize?,
    nextDisplaySize: CGSize,
    nextPresentationSize: CGSize,
    tolerance: CGFloat = 1
)
-> Bool {
    guard let previousDisplaySize else { return true }
    let previousPresentationSize = previousPresentationSize ?? previousDisplaySize
    return abs(previousDisplaySize.width - nextDisplaySize.width) > tolerance ||
        abs(previousDisplaySize.height - nextDisplaySize.height) > tolerance ||
        abs(previousPresentationSize.width - nextPresentationSize.width) > tolerance ||
        abs(previousPresentationSize.height - nextPresentationSize.height) > tolerance
}
