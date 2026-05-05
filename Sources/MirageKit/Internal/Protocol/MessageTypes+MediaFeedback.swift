//
//  MessageTypes+MediaFeedback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Receiver realtime media feedback messages.
//

import Foundation

package enum MirageMediaFeedbackRecoveryState: String, Codable, Sendable, Equatable {
    case idle
    case startup
    case tierPromotionProbe
    case keyframeRecovery
    case hardRecovery
    case postResizeAwaitingFirstFrame
}

package struct MediaFeedbackFrameRange: Codable, Sendable, Equatable {
    package let startFrame: UInt32
    package let endFrame: UInt32

    package init(startFrame: UInt32, endFrame: UInt32) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

package struct ReceiverMediaFeedbackMessage: Codable, Sendable, Equatable {
    package let streamID: StreamID
    package let sequence: UInt64
    package let sentAtUptime: Double
    package let targetFPS: Int
    package let ackRanges: [MediaFeedbackFrameRange]
    package let lostFrameCount: UInt64
    package let discardedPacketCount: UInt64
    package let jitterP95Ms: Double
    package let jitterP99Ms: Double
    package let queueEstimateFrames: Int
    package let reassemblyBacklogFrames: Int
    package let reassemblyBacklogKeyframes: Int
    package let reassemblyBacklogBytes: Int
    package let decodeBacklogFrames: Int
    package let presentationBacklogFrames: Int
    package let decodedFPS: Double
    package let receivedFPS: Double
    package let rendererAcceptedFPS: Double
    package let rendererPresentedFPS: Double
    package let recoveryState: MirageMediaFeedbackRecoveryState

    package init(
        streamID: StreamID,
        sequence: UInt64,
        sentAtUptime: Double,
        targetFPS: Int,
        ackRanges: [MediaFeedbackFrameRange],
        lostFrameCount: UInt64,
        discardedPacketCount: UInt64,
        jitterP95Ms: Double,
        jitterP99Ms: Double,
        queueEstimateFrames: Int,
        reassemblyBacklogFrames: Int,
        reassemblyBacklogKeyframes: Int,
        reassemblyBacklogBytes: Int,
        decodeBacklogFrames: Int,
        presentationBacklogFrames: Int,
        decodedFPS: Double,
        receivedFPS: Double,
        rendererAcceptedFPS: Double,
        rendererPresentedFPS: Double,
        recoveryState: MirageMediaFeedbackRecoveryState
    ) {
        self.streamID = streamID
        self.sequence = sequence
        self.sentAtUptime = sentAtUptime
        self.targetFPS = max(1, min(240, targetFPS))
        self.ackRanges = ackRanges
        self.lostFrameCount = lostFrameCount
        self.discardedPacketCount = discardedPacketCount
        self.jitterP95Ms = max(0, jitterP95Ms)
        self.jitterP99Ms = max(0, jitterP99Ms)
        self.queueEstimateFrames = max(0, queueEstimateFrames)
        self.reassemblyBacklogFrames = max(0, reassemblyBacklogFrames)
        self.reassemblyBacklogKeyframes = max(0, reassemblyBacklogKeyframes)
        self.reassemblyBacklogBytes = max(0, reassemblyBacklogBytes)
        self.decodeBacklogFrames = max(0, decodeBacklogFrames)
        self.presentationBacklogFrames = max(0, presentationBacklogFrames)
        self.decodedFPS = max(0, decodedFPS)
        self.receivedFPS = max(0, receivedFPS)
        self.rendererAcceptedFPS = max(0, rendererAcceptedFPS)
        self.rendererPresentedFPS = max(0, rendererPresentedFPS)
        self.recoveryState = recoveryState
    }
}
