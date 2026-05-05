//
//  RealtimeMediaSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Shared realtime media session state.
//

import Foundation

package struct RealtimeMediaSession: Sendable, Equatable {
    package private(set) var streamID: StreamID
    package private(set) var mediaEpoch: UInt64
    package private(set) var targetFrameRate: Int
    package private(set) var isPaused: Bool
    package private(set) var recoveryState: MirageMediaFeedbackRecoveryState
    package private(set) var latestFeedback: ReceiverMediaFeedbackMessage?
    package private(set) var latestAdaptationReason: String?
    package private(set) var diagnosticsRevision: UInt64

    package init(
        streamID: StreamID,
        targetFrameRate: Int,
        mediaEpoch: UInt64 = 0
    ) {
        self.streamID = streamID
        self.mediaEpoch = mediaEpoch
        self.targetFrameRate = max(1, min(240, targetFrameRate))
        self.isPaused = false
        self.recoveryState = .idle
        self.latestFeedback = nil
        self.latestAdaptationReason = nil
        self.diagnosticsRevision = 0
    }

    package mutating func updateTargetFrameRate(_ frameRate: Int) {
        targetFrameRate = max(1, min(240, frameRate))
        diagnosticsRevision &+= 1
    }

    package mutating func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        diagnosticsRevision &+= 1
    }

    package mutating func setRecoveryState(_ state: MirageMediaFeedbackRecoveryState) {
        guard recoveryState != state else { return }
        recoveryState = state
        diagnosticsRevision &+= 1
    }

    package mutating func recordFeedback(_ feedback: ReceiverMediaFeedbackMessage) {
        latestFeedback = feedback
        targetFrameRate = feedback.targetFPS
        recoveryState = feedback.recoveryState
        diagnosticsRevision &+= 1
    }

    package mutating func recordAdaptation(reason: String) {
        latestAdaptationReason = reason
        diagnosticsRevision &+= 1
    }

    package mutating func advanceEpoch(reason: String) {
        mediaEpoch &+= 1
        latestAdaptationReason = reason
        diagnosticsRevision &+= 1
    }
}
