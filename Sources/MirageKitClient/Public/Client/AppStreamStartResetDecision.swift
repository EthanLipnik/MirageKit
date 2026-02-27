//
//  AppStreamStartResetDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App stream start reset decisions.
//

import MirageKit

enum AppStreamStartResetDecision: Equatable {
    case resetController
    case reuseController
}

func appStreamStartResetDecision(
    streamID: StreamID,
    isExistingStream: Bool,
    hasController: Bool,
    requestStartPending: Bool,
    previousDimensionToken: UInt16?,
    receivedDimensionToken: UInt16?
) -> AppStreamStartResetDecision {
    if requestStartPending { return .resetController }
    if !isExistingStream { return .resetController }
    if !hasController { return .resetController }

    if let previousDimensionToken, let receivedDimensionToken, previousDimensionToken != receivedDimensionToken {
        return .resetController
    }

    _ = streamID // retained for parity with desktop helper signature.
    return .reuseController
}
