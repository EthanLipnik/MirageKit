//
//  MirageMediaFeedbackTypes.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
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

package enum ReceiverMediaFeedbackReliabilityCause: String, Codable, Sendable, Equatable, Hashable {
    case noProgressTimeout
    case absoluteLifetimeTimeout
    case forwardGapStall
    case keyframeStarvation
    case presentationLifecycle
    case appLifecycle
    case memoryPressure
}

package struct MediaFeedbackFrameRange: Codable, Sendable, Equatable {
    package let startFrame: UInt32
    package let endFrame: UInt32

    package init(startFrame: UInt32, endFrame: UInt32) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

package struct ReceiverPFrameTimingSample: Codable, Sendable, Equatable {
    package let frameNumber: UInt32
    package let packetSpanMs: Double
    package let completionGapMs: Double
    package let completionAgeAtFeedbackMs: Double
    package let firstPacketGapMs: Double

    package init(
        frameNumber: UInt32,
        packetSpanMs: Double,
        completionGapMs: Double,
        completionAgeAtFeedbackMs: Double,
        firstPacketGapMs: Double
    ) {
        self.frameNumber = frameNumber
        self.packetSpanMs = max(0, packetSpanMs)
        self.completionGapMs = max(0, completionGapMs)
        self.completionAgeAtFeedbackMs = max(0, completionAgeAtFeedbackMs)
        self.firstPacketGapMs = max(0, firstPacketGapMs)
    }
}
