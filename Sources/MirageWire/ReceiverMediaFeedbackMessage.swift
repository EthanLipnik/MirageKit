//
//  ReceiverMediaFeedbackMessage.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageCore

package struct ReceiverMediaFeedbackMessage: Sendable, Equatable {
    package let streamID: StreamID
    package let sequence: UInt64
    package let sentAtUptime: Double
    package let targetFPS: Int
    package let ackRanges: [MediaFeedbackFrameRange]
    package let pFrameTimingSamples: [ReceiverPFrameTimingSample]
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
    package let recoveryCause: MirageMediaFeedbackRecoveryCause
    package let frameCompletionLatencyP50Ms: Double?
    package let frameCompletionLatencyP95Ms: Double?
    package let frameCompletionLatencyMaxMs: Double?
    package let keyframeCompletionLatencyP50Ms: Double?
    package let keyframeCompletionLatencyP95Ms: Double?
    package let keyframeCompletionLatencyMaxMs: Double?
    package let pFrameCompletionLatencyP50Ms: Double?
    package let pFrameCompletionLatencyP95Ms: Double?
    package let pFrameCompletionLatencyMaxMs: Double?
    package let latePFrameCount: UInt64?
    package let receivedWorstGapMs: Double?
    package let presentationStallCount: UInt64?
    package let displayTickNoFrameCount: UInt64?
    package let pendingFrameNotReadyDisplayTickCount: UInt64?
    package let worstPresentationGapMs: Double?
    package let playoutDelayFrames: Int?
    package let playoutDelayTargetMs: Double?
    package let reassemblerIncompleteFrameTimeouts: UInt64?
    package let reassemblerMissingFragmentTimeouts: UInt64?
    package let reassemblerForwardGapTimeouts: UInt64?
    package let fecRecoveredFragmentCount: UInt64?
    package let reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause]
    package let latestAcceptedFrameNumber: UInt32?
    package let latestPresentedFrameNumber: UInt32?
    package let latestPresentedFrameAgeMs: Double?
    package let decodeQueueDepth: Int?
    package let decodeSubmissionLimit: Int?
    package let inFlightDecodeSubmissions: Int?
    package let presentationQueueDepth: Int?
    package let presentationTargetFrames: Int?
    package let presentationFillDeficitFrames: Int?
    package let presentationUnderfillFrames: Int?
    package let receiverJitterP95Ms: Double?
    package let receiverJitterP99Ms: Double?
    package let audioDroppedFrameCount: UInt64?
    package let audioGateActive: Bool?

    package init(
        streamID: StreamID,
        sequence: UInt64,
        sentAtUptime: Double,
        targetFPS: Int,
        ackRanges: [MediaFeedbackFrameRange],
        pFrameTimingSamples: [ReceiverPFrameTimingSample] = [],
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
        recoveryCause: MirageMediaFeedbackRecoveryCause = .none,
        frameCompletionLatencyP50Ms: Double? = nil,
        frameCompletionLatencyP95Ms: Double? = nil,
        frameCompletionLatencyMaxMs: Double? = nil,
        keyframeCompletionLatencyP50Ms: Double? = nil,
        keyframeCompletionLatencyP95Ms: Double? = nil,
        keyframeCompletionLatencyMaxMs: Double? = nil,
        pFrameCompletionLatencyP50Ms: Double? = nil,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        pFrameCompletionLatencyMaxMs: Double? = nil,
        latePFrameCount: UInt64? = nil,
        receivedWorstGapMs: Double? = nil,
        presentationStallCount: UInt64? = nil,
        displayTickNoFrameCount: UInt64? = nil,
        pendingFrameNotReadyDisplayTickCount: UInt64? = nil,
        worstPresentationGapMs: Double? = nil,
        playoutDelayFrames: Int? = nil,
        playoutDelayTargetMs: Double? = nil,
        reassemblerIncompleteFrameTimeouts: UInt64? = nil,
        reassemblerMissingFragmentTimeouts: UInt64? = nil,
        reassemblerForwardGapTimeouts: UInt64? = nil,
        fecRecoveredFragmentCount: UInt64? = nil,
        reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause] = [],
        latestAcceptedFrameNumber: UInt32? = nil,
        latestPresentedFrameNumber: UInt32? = nil,
        latestPresentedFrameAgeMs: Double? = nil,
        decodeQueueDepth: Int? = nil,
        decodeSubmissionLimit: Int? = nil,
        inFlightDecodeSubmissions: Int? = nil,
        presentationQueueDepth: Int? = nil,
        presentationTargetFrames: Int? = nil,
        presentationFillDeficitFrames: Int? = nil,
        presentationUnderfillFrames: Int? = nil,
        receiverJitterP95Ms: Double? = nil,
        receiverJitterP99Ms: Double? = nil,
        audioDroppedFrameCount: UInt64? = nil,
        audioGateActive: Bool? = nil
    ) {
        self.streamID = streamID
        self.sequence = sequence
        self.sentAtUptime = sentAtUptime
        self.targetFPS = max(1, min(240, targetFPS))
        self.ackRanges = ackRanges
        self.pFrameTimingSamples = Array(pFrameTimingSamples.suffix(Self.maximumPFrameTimingSamples))
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
        self.recoveryCause = recoveryState == .idle ? .none : recoveryCause
        self.frameCompletionLatencyP50Ms = frameCompletionLatencyP50Ms.map { max(0, $0) }
        self.frameCompletionLatencyP95Ms = frameCompletionLatencyP95Ms.map { max(0, $0) }
        self.frameCompletionLatencyMaxMs = frameCompletionLatencyMaxMs.map { max(0, $0) }
        self.keyframeCompletionLatencyP50Ms = keyframeCompletionLatencyP50Ms.map { max(0, $0) }
        self.keyframeCompletionLatencyP95Ms = keyframeCompletionLatencyP95Ms.map { max(0, $0) }
        self.keyframeCompletionLatencyMaxMs = keyframeCompletionLatencyMaxMs.map { max(0, $0) }
        self.pFrameCompletionLatencyP50Ms = pFrameCompletionLatencyP50Ms.map { max(0, $0) }
        self.pFrameCompletionLatencyP95Ms = pFrameCompletionLatencyP95Ms.map { max(0, $0) }
        self.pFrameCompletionLatencyMaxMs = pFrameCompletionLatencyMaxMs.map { max(0, $0) }
        self.latePFrameCount = latePFrameCount
        self.receivedWorstGapMs = receivedWorstGapMs.map { max(0, $0) }
        self.presentationStallCount = presentationStallCount
        self.displayTickNoFrameCount = displayTickNoFrameCount
        self.pendingFrameNotReadyDisplayTickCount = pendingFrameNotReadyDisplayTickCount
        self.worstPresentationGapMs = worstPresentationGapMs.map { max(0, $0) }
        self.playoutDelayFrames = playoutDelayFrames.map { max(0, $0) }
        self.playoutDelayTargetMs = playoutDelayTargetMs.map { max(0, $0) }
        self.reassemblerIncompleteFrameTimeouts = reassemblerIncompleteFrameTimeouts
        self.reassemblerMissingFragmentTimeouts = reassemblerMissingFragmentTimeouts
        self.reassemblerForwardGapTimeouts = reassemblerForwardGapTimeouts
        self.fecRecoveredFragmentCount = fecRecoveredFragmentCount
        self.reliabilityCauses = reliabilityCauses
        self.latestAcceptedFrameNumber = latestAcceptedFrameNumber
        self.latestPresentedFrameNumber = latestPresentedFrameNumber
        self.latestPresentedFrameAgeMs = latestPresentedFrameAgeMs.map { max(0, $0) }
        self.decodeQueueDepth = decodeQueueDepth.map { max(0, $0) }
        self.decodeSubmissionLimit = decodeSubmissionLimit.map { max(0, $0) }
        self.inFlightDecodeSubmissions = inFlightDecodeSubmissions.map { max(0, $0) }
        self.presentationQueueDepth = presentationQueueDepth.map { max(0, $0) }
        self.presentationTargetFrames = presentationTargetFrames.map { max(0, $0) }
        self.presentationFillDeficitFrames = presentationFillDeficitFrames.map { max(0, $0) }
        self.presentationUnderfillFrames = presentationUnderfillFrames.map { max(0, $0) }
        self.receiverJitterP95Ms = receiverJitterP95Ms.map { max(0, $0) }
        self.receiverJitterP99Ms = receiverJitterP99Ms.map { max(0, $0) }
        self.audioDroppedFrameCount = audioDroppedFrameCount
        self.audioGateActive = audioGateActive
    }

    static let maximumPFrameTimingSamples = 128
}
