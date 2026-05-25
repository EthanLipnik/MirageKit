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
    package let pFrameCompletionLatencyP50Ms: Double?
    package let pFrameCompletionLatencyP95Ms: Double?
    package let pFrameCompletionLatencyMaxMs: Double?
    package let latePFrameCount: UInt64?
    package let receivedWorstGapMs: Double?
    package let presentationStallCount: UInt64?
    package let displayTickNoFrameCount: UInt64?
    package let worstPresentationGapMs: Double?
    package let playoutDelayFrames: Int?
    package let playoutDelayTargetMs: Double?
    package let reassemblerIncompleteFrameTimeouts: UInt64?
    package let reassemblerMissingFragmentTimeouts: UInt64?
    package let reassemblerForwardGapTimeouts: UInt64?
    package let fecRecoveredFragmentCount: UInt64?
    package let reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause]

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
        recoveryState: MirageMediaFeedbackRecoveryState,
        pFrameCompletionLatencyP50Ms: Double? = nil,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        pFrameCompletionLatencyMaxMs: Double? = nil,
        latePFrameCount: UInt64? = nil,
        receivedWorstGapMs: Double? = nil,
        presentationStallCount: UInt64? = nil,
        displayTickNoFrameCount: UInt64? = nil,
        worstPresentationGapMs: Double? = nil,
        playoutDelayFrames: Int? = nil,
        playoutDelayTargetMs: Double? = nil,
        reassemblerIncompleteFrameTimeouts: UInt64? = nil,
        reassemblerMissingFragmentTimeouts: UInt64? = nil,
        reassemblerForwardGapTimeouts: UInt64? = nil,
        fecRecoveredFragmentCount: UInt64? = nil,
        reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause] = []
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
        self.pFrameCompletionLatencyP50Ms = pFrameCompletionLatencyP50Ms.map { max(0, $0) }
        self.pFrameCompletionLatencyP95Ms = pFrameCompletionLatencyP95Ms.map { max(0, $0) }
        self.pFrameCompletionLatencyMaxMs = pFrameCompletionLatencyMaxMs.map { max(0, $0) }
        self.latePFrameCount = latePFrameCount
        self.receivedWorstGapMs = receivedWorstGapMs.map { max(0, $0) }
        self.presentationStallCount = presentationStallCount
        self.displayTickNoFrameCount = displayTickNoFrameCount
        self.worstPresentationGapMs = worstPresentationGapMs.map { max(0, $0) }
        self.playoutDelayFrames = playoutDelayFrames.map { max(0, $0) }
        self.playoutDelayTargetMs = playoutDelayTargetMs.map { max(0, $0) }
        self.reassemblerIncompleteFrameTimeouts = reassemblerIncompleteFrameTimeouts
        self.reassemblerMissingFragmentTimeouts = reassemblerMissingFragmentTimeouts
        self.reassemblerForwardGapTimeouts = reassemblerForwardGapTimeouts
        self.fecRecoveredFragmentCount = fecRecoveredFragmentCount
        self.reliabilityCauses = reliabilityCauses
    }

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
        self.init(
            streamID: streamID,
            sequence: sequence,
            sentAtUptime: sentAtUptime,
            targetFPS: targetFPS,
            ackRanges: ackRanges,
            lostFrameCount: lostFrameCount,
            discardedPacketCount: discardedPacketCount,
            jitterP95Ms: jitterP95Ms,
            jitterP99Ms: jitterP99Ms,
            queueEstimateFrames: queueEstimateFrames,
            reassemblyBacklogFrames: reassemblyBacklogFrames,
            reassemblyBacklogKeyframes: reassemblyBacklogKeyframes,
            reassemblyBacklogBytes: reassemblyBacklogBytes,
            decodeBacklogFrames: decodeBacklogFrames,
            presentationBacklogFrames: presentationBacklogFrames,
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            rendererAcceptedFPS: rendererAcceptedFPS,
            rendererPresentedFPS: rendererPresentedFPS,
            recoveryState: recoveryState,
            pFrameCompletionLatencyP50Ms: nil,
            pFrameCompletionLatencyP95Ms: nil,
            pFrameCompletionLatencyMaxMs: nil,
            latePFrameCount: nil,
            receivedWorstGapMs: nil,
            presentationStallCount: nil,
            displayTickNoFrameCount: nil,
            worstPresentationGapMs: nil,
            playoutDelayFrames: nil,
            playoutDelayTargetMs: nil,
            reassemblerIncompleteFrameTimeouts: nil,
            reassemblerMissingFragmentTimeouts: nil,
            reassemblerForwardGapTimeouts: nil,
            fecRecoveredFragmentCount: nil,
            reliabilityCauses: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case sequence
        case sentAtUptime
        case targetFPS
        case ackRanges
        case lostFrameCount
        case discardedPacketCount
        case jitterP95Ms
        case jitterP99Ms
        case queueEstimateFrames
        case reassemblyBacklogFrames
        case reassemblyBacklogKeyframes
        case reassemblyBacklogBytes
        case decodeBacklogFrames
        case presentationBacklogFrames
        case decodedFPS
        case receivedFPS
        case rendererAcceptedFPS
        case rendererPresentedFPS
        case recoveryState
        case pFrameCompletionLatencyP50Ms
        case pFrameCompletionLatencyP95Ms
        case pFrameCompletionLatencyMaxMs
        case latePFrameCount
        case receivedWorstGapMs
        case presentationStallCount
        case displayTickNoFrameCount
        case worstPresentationGapMs
        case playoutDelayFrames
        case playoutDelayTargetMs
        case reassemblerIncompleteFrameTimeouts
        case reassemblerMissingFragmentTimeouts
        case reassemblerForwardGapTimeouts
        case fecRecoveredFragmentCount
        case reliabilityCauses
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            streamID: try container.decode(StreamID.self, forKey: .streamID),
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            sentAtUptime: try container.decode(Double.self, forKey: .sentAtUptime),
            targetFPS: try container.decode(Int.self, forKey: .targetFPS),
            ackRanges: try container.decodeIfPresent([MediaFeedbackFrameRange].self, forKey: .ackRanges) ?? [],
            lostFrameCount: try container.decodeIfPresent(UInt64.self, forKey: .lostFrameCount) ?? 0,
            discardedPacketCount: try container.decodeIfPresent(UInt64.self, forKey: .discardedPacketCount) ?? 0,
            jitterP95Ms: try container.decodeIfPresent(Double.self, forKey: .jitterP95Ms) ?? 0,
            jitterP99Ms: try container.decodeIfPresent(Double.self, forKey: .jitterP99Ms) ?? 0,
            queueEstimateFrames: try container.decodeIfPresent(Int.self, forKey: .queueEstimateFrames) ?? 0,
            reassemblyBacklogFrames: try container.decodeIfPresent(Int.self, forKey: .reassemblyBacklogFrames) ?? 0,
            reassemblyBacklogKeyframes: try container.decodeIfPresent(
                Int.self,
                forKey: .reassemblyBacklogKeyframes
            ) ?? 0,
            reassemblyBacklogBytes: try container.decodeIfPresent(Int.self, forKey: .reassemblyBacklogBytes) ?? 0,
            decodeBacklogFrames: try container.decodeIfPresent(Int.self, forKey: .decodeBacklogFrames) ?? 0,
            presentationBacklogFrames: try container.decodeIfPresent(
                Int.self,
                forKey: .presentationBacklogFrames
            ) ?? 0,
            decodedFPS: try container.decodeIfPresent(Double.self, forKey: .decodedFPS) ?? 0,
            receivedFPS: try container.decodeIfPresent(Double.self, forKey: .receivedFPS) ?? 0,
            rendererAcceptedFPS: try container.decodeIfPresent(Double.self, forKey: .rendererAcceptedFPS) ?? 0,
            rendererPresentedFPS: try container.decodeIfPresent(Double.self, forKey: .rendererPresentedFPS) ?? 0,
            recoveryState: try container.decodeIfPresent(
                MirageMediaFeedbackRecoveryState.self,
                forKey: .recoveryState
            ) ?? .idle,
            pFrameCompletionLatencyP50Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .pFrameCompletionLatencyP50Ms
            ),
            pFrameCompletionLatencyP95Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .pFrameCompletionLatencyP95Ms
            ),
            pFrameCompletionLatencyMaxMs: try container.decodeIfPresent(
                Double.self,
                forKey: .pFrameCompletionLatencyMaxMs
            ),
            latePFrameCount: try container.decodeIfPresent(UInt64.self, forKey: .latePFrameCount),
            receivedWorstGapMs: try container.decodeIfPresent(Double.self, forKey: .receivedWorstGapMs),
            presentationStallCount: try container.decodeIfPresent(UInt64.self, forKey: .presentationStallCount),
            displayTickNoFrameCount: try container.decodeIfPresent(UInt64.self, forKey: .displayTickNoFrameCount),
            worstPresentationGapMs: try container.decodeIfPresent(Double.self, forKey: .worstPresentationGapMs),
            playoutDelayFrames: try container.decodeIfPresent(Int.self, forKey: .playoutDelayFrames),
            playoutDelayTargetMs: try container.decodeIfPresent(Double.self, forKey: .playoutDelayTargetMs),
            reassemblerIncompleteFrameTimeouts: try container.decodeIfPresent(
                UInt64.self,
                forKey: .reassemblerIncompleteFrameTimeouts
            ),
            reassemblerMissingFragmentTimeouts: try container.decodeIfPresent(
                UInt64.self,
                forKey: .reassemblerMissingFragmentTimeouts
            ),
            reassemblerForwardGapTimeouts: try container.decodeIfPresent(
                UInt64.self,
                forKey: .reassemblerForwardGapTimeouts
            ),
            fecRecoveredFragmentCount: try container.decodeIfPresent(
                UInt64.self,
                forKey: .fecRecoveredFragmentCount
            ),
            reliabilityCauses: try container.decodeIfPresent(
                [ReceiverMediaFeedbackReliabilityCause].self,
                forKey: .reliabilityCauses
            ) ?? []
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(sentAtUptime, forKey: .sentAtUptime)
        try container.encode(targetFPS, forKey: .targetFPS)
        try container.encode(ackRanges, forKey: .ackRanges)
        try container.encode(lostFrameCount, forKey: .lostFrameCount)
        try container.encode(discardedPacketCount, forKey: .discardedPacketCount)
        try container.encode(jitterP95Ms, forKey: .jitterP95Ms)
        try container.encode(jitterP99Ms, forKey: .jitterP99Ms)
        try container.encode(queueEstimateFrames, forKey: .queueEstimateFrames)
        try container.encode(reassemblyBacklogFrames, forKey: .reassemblyBacklogFrames)
        try container.encode(reassemblyBacklogKeyframes, forKey: .reassemblyBacklogKeyframes)
        try container.encode(reassemblyBacklogBytes, forKey: .reassemblyBacklogBytes)
        try container.encode(decodeBacklogFrames, forKey: .decodeBacklogFrames)
        try container.encode(presentationBacklogFrames, forKey: .presentationBacklogFrames)
        try container.encode(decodedFPS, forKey: .decodedFPS)
        try container.encode(receivedFPS, forKey: .receivedFPS)
        try container.encode(rendererAcceptedFPS, forKey: .rendererAcceptedFPS)
        try container.encode(rendererPresentedFPS, forKey: .rendererPresentedFPS)
        try container.encode(recoveryState, forKey: .recoveryState)
        try container.encodeIfPresent(pFrameCompletionLatencyP50Ms, forKey: .pFrameCompletionLatencyP50Ms)
        try container.encodeIfPresent(pFrameCompletionLatencyP95Ms, forKey: .pFrameCompletionLatencyP95Ms)
        try container.encodeIfPresent(pFrameCompletionLatencyMaxMs, forKey: .pFrameCompletionLatencyMaxMs)
        try container.encodeIfPresent(latePFrameCount, forKey: .latePFrameCount)
        try container.encodeIfPresent(receivedWorstGapMs, forKey: .receivedWorstGapMs)
        try container.encodeIfPresent(presentationStallCount, forKey: .presentationStallCount)
        try container.encodeIfPresent(displayTickNoFrameCount, forKey: .displayTickNoFrameCount)
        try container.encodeIfPresent(worstPresentationGapMs, forKey: .worstPresentationGapMs)
        try container.encodeIfPresent(playoutDelayFrames, forKey: .playoutDelayFrames)
        try container.encodeIfPresent(playoutDelayTargetMs, forKey: .playoutDelayTargetMs)
        try container.encodeIfPresent(
            reassemblerIncompleteFrameTimeouts,
            forKey: .reassemblerIncompleteFrameTimeouts
        )
        try container.encodeIfPresent(reassemblerMissingFragmentTimeouts, forKey: .reassemblerMissingFragmentTimeouts)
        try container.encodeIfPresent(reassemblerForwardGapTimeouts, forKey: .reassemblerForwardGapTimeouts)
        try container.encodeIfPresent(fecRecoveredFragmentCount, forKey: .fecRecoveredFragmentCount)
        if !reliabilityCauses.isEmpty {
            try container.encode(reliabilityCauses, forKey: .reliabilityCauses)
        }
    }
}
