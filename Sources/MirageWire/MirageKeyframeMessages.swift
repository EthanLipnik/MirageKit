//
//  MirageKeyframeMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

// MARK: - Keyframe Messages

package enum MirageMediaFeedbackRecoveryCause: String, Codable, Sendable, Equatable {
    case none
    case decodeError
    case frameLoss
    case freezeTimeout
    case memoryBudget
    case startupTimeout
    case manual
}

/// Client-to-host request for a fresh keyframe on a stream.
package struct KeyframeRequestMessage: Codable {
    /// Stream that needs a keyframe.
    package let streamID: StreamID

    /// Recovery cause that allows the host to distinguish decode-error repair from frame-loss churn.
    package let recoveryCause: MirageMediaFeedbackRecoveryCause

    /// Creates a keyframe request.
    package init(
        streamID: StreamID,
        recoveryCause: MirageMediaFeedbackRecoveryCause = .none
    ) {
        self.streamID = streamID
        self.recoveryCause = recoveryCause
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case recoveryCause
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(StreamID.self, forKey: .streamID)
        recoveryCause = try container.decodeIfPresent(
            MirageMediaFeedbackRecoveryCause.self,
            forKey: .recoveryCause
        ) ?? .none
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        if recoveryCause != .none {
            try container.encode(recoveryCause, forKey: .recoveryCause)
        }
    }
}

/// Host-to-client acknowledgement for keyframe recovery state.
package enum KeyframeRecoveryAckState: String, Codable, Sendable, Equatable {
    case accepted
    case inFlight
    case cooldown
    case noStream
}

package struct KeyframeRecoveryAckMessage: Codable, Sendable, Equatable {
    /// Stream whose recovery request was evaluated.
    package let streamID: StreamID

    /// Estimated recovery deadline in milliseconds.
    package let deadlineMilliseconds: Int

    /// Whether the host accepted this request as a new keyframe command.
    package let accepted: Bool

    /// Host-side request state used by the client to pace retry episodes.
    package let state: KeyframeRecoveryAckState

    /// Creates a keyframe recovery acknowledgement.
    package init(
        streamID: StreamID,
        deadlineMilliseconds: Int,
        accepted: Bool = true,
        state: KeyframeRecoveryAckState = .accepted
    ) {
        self.streamID = streamID
        self.deadlineMilliseconds = max(0, deadlineMilliseconds)
        self.accepted = accepted
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case deadlineMilliseconds
        case accepted
        case state
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(StreamID.self, forKey: .streamID)
        deadlineMilliseconds = max(
            0,
            try container.decode(Int.self, forKey: .deadlineMilliseconds)
        )
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
        state = try container.decodeIfPresent(KeyframeRecoveryAckState.self, forKey: .state) ??
            (accepted ? .accepted : .cooldown)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(deadlineMilliseconds, forKey: .deadlineMilliseconds)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(state, forKey: .state)
    }
}
