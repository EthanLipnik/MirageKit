//
//  ReceiverMediaFeedbackMessage+Codable.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageCore

extension ReceiverMediaFeedbackMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case streamID
        case sequence
        case sentAtUptime
        case targetFPS
        case ackRanges
        case pFrameTimingSamples
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
        case recoveryCause
        case frameCompletionLatencyP50Ms
        case frameCompletionLatencyP95Ms
        case frameCompletionLatencyMaxMs
        case keyframeCompletionLatencyP50Ms
        case keyframeCompletionLatencyP95Ms
        case keyframeCompletionLatencyMaxMs
        case pFrameCompletionLatencyP50Ms
        case pFrameCompletionLatencyP95Ms
        case pFrameCompletionLatencyMaxMs
        case latePFrameCount
        case receivedWorstGapMs
        case presentationStallCount
        case displayTickNoFrameCount
        case pendingFrameNotReadyDisplayTickCount
        case worstPresentationGapMs
        case playoutDelayFrames
        case playoutDelayTargetMs
        case reassemblerIncompleteFrameTimeouts
        case reassemblerMissingFragmentTimeouts
        case reassemblerForwardGapTimeouts
        case fecRecoveredFragmentCount
        case reliabilityCauses
        case latestAcceptedFrameNumber
        case latestPresentedFrameNumber
        case latestPresentedFrameAgeMs
        case decodeQueueDepth
        case decodeSubmissionLimit
        case inFlightDecodeSubmissions
        case presentationQueueDepth
        case presentationTargetFrames
        case presentationFillDeficitFrames
        case presentationUnderfillFrames
        case receiverJitterP95Ms
        case receiverJitterP99Ms
        case audioDroppedFrameCount
        case audioGateActive
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            streamID: try container.decode(StreamID.self, forKey: .streamID),
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            sentAtUptime: try container.decode(Double.self, forKey: .sentAtUptime),
            targetFPS: try container.decode(Int.self, forKey: .targetFPS),
            ackRanges: try container.decodeIfPresent([MediaFeedbackFrameRange].self, forKey: .ackRanges) ?? [],
            pFrameTimingSamples: try container.decodeIfPresent(
                [ReceiverPFrameTimingSample].self,
                forKey: .pFrameTimingSamples
            ) ?? [],
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
            recoveryCause: try container.decodeIfPresent(
                MirageMediaFeedbackRecoveryCause.self,
                forKey: .recoveryCause
            ) ?? .none,
            frameCompletionLatencyP50Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .frameCompletionLatencyP50Ms
            ),
            frameCompletionLatencyP95Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .frameCompletionLatencyP95Ms
            ),
            frameCompletionLatencyMaxMs: try container.decodeIfPresent(
                Double.self,
                forKey: .frameCompletionLatencyMaxMs
            ),
            keyframeCompletionLatencyP50Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .keyframeCompletionLatencyP50Ms
            ),
            keyframeCompletionLatencyP95Ms: try container.decodeIfPresent(
                Double.self,
                forKey: .keyframeCompletionLatencyP95Ms
            ),
            keyframeCompletionLatencyMaxMs: try container.decodeIfPresent(
                Double.self,
                forKey: .keyframeCompletionLatencyMaxMs
            ),
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
            pendingFrameNotReadyDisplayTickCount: try container.decodeIfPresent(
                UInt64.self,
                forKey: .pendingFrameNotReadyDisplayTickCount
            ),
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
            ) ?? [],
            latestAcceptedFrameNumber: try container.decodeIfPresent(
                UInt32.self,
                forKey: .latestAcceptedFrameNumber
            ),
            latestPresentedFrameNumber: try container.decodeIfPresent(
                UInt32.self,
                forKey: .latestPresentedFrameNumber
            ),
            latestPresentedFrameAgeMs: try container.decodeIfPresent(
                Double.self,
                forKey: .latestPresentedFrameAgeMs
            ),
            decodeQueueDepth: try container.decodeIfPresent(Int.self, forKey: .decodeQueueDepth),
            decodeSubmissionLimit: try container.decodeIfPresent(Int.self, forKey: .decodeSubmissionLimit),
            inFlightDecodeSubmissions: try container.decodeIfPresent(
                Int.self,
                forKey: .inFlightDecodeSubmissions
            ),
            presentationQueueDepth: try container.decodeIfPresent(Int.self, forKey: .presentationQueueDepth),
            presentationTargetFrames: try container.decodeIfPresent(Int.self, forKey: .presentationTargetFrames),
            presentationFillDeficitFrames: try container.decodeIfPresent(
                Int.self,
                forKey: .presentationFillDeficitFrames
            ),
            presentationUnderfillFrames: try container.decodeIfPresent(Int.self, forKey: .presentationUnderfillFrames),
            receiverJitterP95Ms: try container.decodeIfPresent(Double.self, forKey: .receiverJitterP95Ms),
            receiverJitterP99Ms: try container.decodeIfPresent(Double.self, forKey: .receiverJitterP99Ms),
            audioDroppedFrameCount: try container.decodeIfPresent(UInt64.self, forKey: .audioDroppedFrameCount),
            audioGateActive: try container.decodeIfPresent(Bool.self, forKey: .audioGateActive)
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(sentAtUptime, forKey: .sentAtUptime)
        try container.encode(targetFPS, forKey: .targetFPS)
        try container.encode(ackRanges, forKey: .ackRanges)
        try container.encode(pFrameTimingSamples, forKey: .pFrameTimingSamples)
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
        if recoveryCause != .none {
            try container.encode(recoveryCause, forKey: .recoveryCause)
        }
        try container.encodeIfPresent(frameCompletionLatencyP50Ms, forKey: .frameCompletionLatencyP50Ms)
        try container.encodeIfPresent(frameCompletionLatencyP95Ms, forKey: .frameCompletionLatencyP95Ms)
        try container.encodeIfPresent(frameCompletionLatencyMaxMs, forKey: .frameCompletionLatencyMaxMs)
        try container.encodeIfPresent(keyframeCompletionLatencyP50Ms, forKey: .keyframeCompletionLatencyP50Ms)
        try container.encodeIfPresent(keyframeCompletionLatencyP95Ms, forKey: .keyframeCompletionLatencyP95Ms)
        try container.encodeIfPresent(keyframeCompletionLatencyMaxMs, forKey: .keyframeCompletionLatencyMaxMs)
        try container.encodeIfPresent(pFrameCompletionLatencyP50Ms, forKey: .pFrameCompletionLatencyP50Ms)
        try container.encodeIfPresent(pFrameCompletionLatencyP95Ms, forKey: .pFrameCompletionLatencyP95Ms)
        try container.encodeIfPresent(pFrameCompletionLatencyMaxMs, forKey: .pFrameCompletionLatencyMaxMs)
        try container.encodeIfPresent(latePFrameCount, forKey: .latePFrameCount)
        try container.encodeIfPresent(receivedWorstGapMs, forKey: .receivedWorstGapMs)
        try container.encodeIfPresent(presentationStallCount, forKey: .presentationStallCount)
        try container.encodeIfPresent(displayTickNoFrameCount, forKey: .displayTickNoFrameCount)
        try container.encodeIfPresent(
            pendingFrameNotReadyDisplayTickCount,
            forKey: .pendingFrameNotReadyDisplayTickCount
        )
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
        try container.encodeIfPresent(latestAcceptedFrameNumber, forKey: .latestAcceptedFrameNumber)
        try container.encodeIfPresent(latestPresentedFrameNumber, forKey: .latestPresentedFrameNumber)
        try container.encodeIfPresent(latestPresentedFrameAgeMs, forKey: .latestPresentedFrameAgeMs)
        try container.encodeIfPresent(decodeQueueDepth, forKey: .decodeQueueDepth)
        try container.encodeIfPresent(decodeSubmissionLimit, forKey: .decodeSubmissionLimit)
        try container.encodeIfPresent(inFlightDecodeSubmissions, forKey: .inFlightDecodeSubmissions)
        try container.encodeIfPresent(presentationQueueDepth, forKey: .presentationQueueDepth)
        try container.encodeIfPresent(presentationTargetFrames, forKey: .presentationTargetFrames)
        try container.encodeIfPresent(presentationFillDeficitFrames, forKey: .presentationFillDeficitFrames)
        try container.encodeIfPresent(presentationUnderfillFrames, forKey: .presentationUnderfillFrames)
        try container.encodeIfPresent(receiverJitterP95Ms, forKey: .receiverJitterP95Ms)
        try container.encodeIfPresent(receiverJitterP99Ms, forKey: .receiverJitterP99Ms)
        try container.encodeIfPresent(audioDroppedFrameCount, forKey: .audioDroppedFrameCount)
        try container.encodeIfPresent(audioGateActive, forKey: .audioGateActive)
    }
}
