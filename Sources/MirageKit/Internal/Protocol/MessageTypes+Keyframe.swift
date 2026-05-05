//
//  MessageTypes+Keyframe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Keyframe Messages

package struct KeyframeRequestMessage: Codable {
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

package struct KeyframeRecoveryAckMessage: Codable, Sendable, Equatable {
    package let streamID: StreamID
    package let accepted: Bool
    package let hostEpoch: UInt16?
    package let deadlineMilliseconds: Int
    package let reason: String

    package init(
        streamID: StreamID,
        accepted: Bool,
        hostEpoch: UInt16?,
        deadlineMilliseconds: Int,
        reason: String
    ) {
        self.streamID = streamID
        self.accepted = accepted
        self.hostEpoch = hostEpoch
        self.deadlineMilliseconds = max(0, deadlineMilliseconds)
        self.reason = reason
    }
}
