//
//  DesktopStreamStartResetDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start reset decisions.
//

import MirageKit

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
