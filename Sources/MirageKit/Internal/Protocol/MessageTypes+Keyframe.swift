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

/// Client-to-host request for a fresh keyframe on a stream.
package struct KeyframeRequestMessage: Codable {
    /// Stream that needs a keyframe.
    package let streamID: StreamID

    /// Creates a keyframe request.
    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// Host-to-client acknowledgement for keyframe recovery state.
package struct KeyframeRecoveryAckMessage: Codable, Equatable {
    /// Stream whose recovery request was evaluated.
    package let streamID: StreamID

    /// Estimated recovery deadline in milliseconds.
    package let deadlineMilliseconds: Int

    /// Creates a keyframe recovery acknowledgement.
    package init(
        streamID: StreamID,
        deadlineMilliseconds: Int
    ) {
        self.streamID = streamID
        self.deadlineMilliseconds = max(0, deadlineMilliseconds)
    }
}
