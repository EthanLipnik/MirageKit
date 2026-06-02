//
//  ReceiverMediaFeedbackPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

@Suite("Receiver Media Feedback Policy")
struct ReceiverMediaFeedbackPolicyTests {
    @Test("Receiver feedback accepts legacy payloads without timing samples")
    func receiverFeedbackAcceptsLegacyPayloadsWithoutTimingSamples() throws {
        let payload = Data(
            #"""
            {
              "streamID": 1,
              "sequence": 2,
              "sentAtUptime": 10,
              "targetFPS": 60,
              "ackRanges": [],
              "lostFrameCount": 0,
              "discardedPacketCount": 0,
              "jitterP95Ms": 0,
              "jitterP99Ms": 0,
              "queueEstimateFrames": 0,
              "reassemblyBacklogFrames": 0,
              "reassemblyBacklogKeyframes": 0,
              "reassemblyBacklogBytes": 0,
              "decodeBacklogFrames": 0,
              "presentationBacklogFrames": 0,
              "decodedFPS": 60,
              "receivedFPS": 60,
              "rendererAcceptedFPS": 60,
              "rendererPresentedFPS": 60,
              "recoveryState": "idle"
            }
            """#.utf8
        )

        let feedback = try JSONDecoder().decode(ReceiverMediaFeedbackMessage.self, from: payload)
        #expect(feedback.pFrameTimingSamples.isEmpty)
        #expect(feedback.recoveryState == .idle)
    }

    @Test("Receiver feedback timing samples encode and decode")
    func receiverFeedbackTimingSamplesEncodeAndDecode() throws {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 11,
            sentAtUptime: 104,
            targetFPS: 60,
            recoveryState: .idle,
            pFrameTimingSamples: [
                ReceiverPFrameTimingSample(
                    frameNumber: 40,
                    packetSpanMs: 6.5,
                    completionGapMs: 16.7,
                    completionAgeAtFeedbackMs: 3.0,
                    firstPacketGapMs: 16.6
                ),
                ReceiverPFrameTimingSample(
                    frameNumber: 41,
                    packetSpanMs: 12.25,
                    completionGapMs: 18.5,
                    completionAgeAtFeedbackMs: 2.0,
                    firstPacketGapMs: 17.0
                )
            ],
            latestAcceptedFrameNumber: 41,
            latestPresentedFrameNumber: 40,
            latestPresentedFrameAgeMs: 14.5,
            decodeQueueDepth: 2,
            decodeSubmissionLimit: 3,
            inFlightDecodeSubmissions: 2,
            presentationQueueDepth: 1,
            metrics: metrics(
                pendingFrameNotReadyDisplayTickCount: 3,
                reassemblerFrameCompletionLatencyP95Ms: 31,
                reassemblerKeyframeCompletionLatencyP95Ms: 85,
                reassemblerPFrameCompletionLatencyP95Ms: 24
            )
        )

        let encoded = try JSONEncoder().encode(feedback)
        let decoded = try JSONDecoder().decode(ReceiverMediaFeedbackMessage.self, from: encoded)

        #expect(decoded.pFrameTimingSamples == [
            ReceiverPFrameTimingSample(
                frameNumber: 40,
                packetSpanMs: 6.5,
                completionGapMs: 16.7,
                completionAgeAtFeedbackMs: 3.0,
                firstPacketGapMs: 16.6
            ),
            ReceiverPFrameTimingSample(
                frameNumber: 41,
                packetSpanMs: 12.25,
                completionGapMs: 18.5,
                completionAgeAtFeedbackMs: 2.0,
                firstPacketGapMs: 17.0
            )
        ])
        #expect(decoded.latestAcceptedFrameNumber == 41)
        #expect(decoded.latestPresentedFrameNumber == 40)
        #expect(decoded.latestPresentedFrameAgeMs == 14.5)
        #expect(decoded.decodeQueueDepth == 2)
        #expect(decoded.decodeSubmissionLimit == 3)
        #expect(decoded.inFlightDecodeSubmissions == 2)
        #expect(decoded.presentationQueueDepth == 1)
        #expect(decoded.pendingFrameNotReadyDisplayTickCount == 3)
        #expect(decoded.frameCompletionLatencyP95Ms == 31)
        #expect(decoded.keyframeCompletionLatencyP95Ms == 85)
        #expect(decoded.pFrameCompletionLatencyP95Ms == 24)
    }

    @Test("Local render and reassembly symptoms are not reported as transport loss")
    func localPipelineSymptomsAreNotReportedAsTransportLoss() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 7,
            sentAtUptime: 100,
            targetFPS: 60,
            recoveryState: .keyframeRecovery,
            recoveryCause: .frameLoss,
            metrics: metrics(
                droppedFrames: 42,
                decodeBacklogFrames: 18,
                pendingFrameCount: 5,
                smoothestQueueDrops: 9,
                presentationStallCount: 4,
                reassemblerPendingFrameCount: 11,
                reassemblerPendingKeyframeCount: 1,
                reassemblerPendingBytes: 3_000_000,
                reassemblerBudgetEvictions: 6
            )
        )

        #expect(feedback.lostFrameCount == 0)
        #expect(feedback.discardedPacketCount == 0)
        #expect(feedback.reassemblyBacklogFrames == 11)
        #expect(feedback.reassemblyBacklogKeyframes == 1)
        #expect(feedback.decodeBacklogFrames == 18)
        #expect(feedback.presentationQueueDepth == nil)
        #expect(feedback.presentationBacklogFrames == 5)
        #expect(feedback.recoveryState == .keyframeRecovery)
        #expect(feedback.recoveryCause == .frameLoss)
        #expect(feedback.reliabilityCauses.contains(.keyframeStarvation))
        #expect(feedback.reliabilityCauses.contains(.memoryPressure))
    }

    @Test("Healthy buffered playout depth is not reported as presentation backlog")
    func healthyBufferedPlayoutDepthIsNotReportedAsPresentationBacklog() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 12,
            sentAtUptime: 105,
            targetFPS: 60,
            recoveryState: .idle,
            presentationQueueDepth: 5,
            metrics: metrics(
                pendingFrameCount: 5,
                smoothestTargetDelayMs: 80
            )
        )

        #expect(feedback.queueEstimateFrames == 5)
        #expect(feedback.presentationQueueDepth == 5)
        #expect(feedback.presentationTargetFrames == 5)
        #expect(feedback.presentationBacklogFrames == 0)
        #expect(feedback.presentationFillDeficitFrames == 0)
        #expect(feedback.presentationUnderfillFrames == 0)
    }

    @Test("Buffered fill deficit without a presentation miss is reported before underflow")
    func bufferedFillDeficitWithoutPresentationMissIsReportedBeforeUnderflow() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 13,
            sentAtUptime: 106,
            targetFPS: 60,
            recoveryState: .idle,
            presentationQueueDepth: 1,
            metrics: metrics(
                pendingFrameCount: 1,
                smoothestTargetDelayMs: 140
            )
        )

        #expect(feedback.presentationQueueDepth == 1)
        #expect(feedback.presentationTargetFrames == 9)
        #expect(feedback.presentationBacklogFrames == 0)
        #expect(feedback.presentationFillDeficitFrames == 8)
        #expect(feedback.presentationUnderfillFrames == 0)
    }

    @Test("Transport-proven receiver fragment loss is reported separately from local drops")
    func transportProvenFragmentLossIsReported() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 8,
            sentAtUptime: 101,
            targetFPS: 120,
            recoveryState: .idle,
            transportLostFrameCount: 1,
            transportDiscardedPacketCount: 12,
            metrics: metrics(
                droppedFrames: 50,
                smoothestQueueDrops: 20,
                reassemblerPendingFrameCount: 0,
                reassemblerPendingKeyframeCount: 0,
                reassemblerPendingBytes: 0
            )
        )

        #expect(feedback.lostFrameCount == 1)
        #expect(feedback.discardedPacketCount == 12)
        #expect(feedback.recoveryState == .idle)
    }

    @Test("Raw ingress jitter is reported as receiver jitter pressure")
    func rawIngressJitterIsReportedAsReceiverJitterPressure() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 14,
            sentAtUptime: 107,
            targetFPS: 60,
            recoveryState: .idle,
            metrics: metrics(
                receivedFrameIntervalP95Ms: 18,
                receivedFrameIntervalP99Ms: 22,
                receiverIngressJitterP95Ms: 28,
                receiverIngressJitterP99Ms: 74
            )
        )

        #expect(feedback.jitterP99Ms == 22)
        #expect(feedback.receiverJitterP95Ms == 28)
        #expect(feedback.receiverJitterP99Ms == 74)
    }

    @Test("AWDL receiver jitter uses packet ingress jitter instead of completed frame gaps")
    func awdlReceiverJitterUsesIngressJitterInsteadOfCompletedFrameGaps() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 15,
            sentAtUptime: 108,
            targetFPS: 60,
            recoveryState: .idle,
            mediaPathProfile: .awdlRadio,
            metrics: metrics(
                receivedFrameIntervalP95Ms: 120,
                receivedFrameIntervalP99Ms: 180,
                receiverIngressJitterP95Ms: 7,
                receiverIngressJitterP99Ms: 11
            )
        )

        #expect(feedback.jitterP95Ms == 120)
        #expect(feedback.jitterP99Ms == 180)
        #expect(feedback.receiverJitterP95Ms == 7)
        #expect(feedback.receiverJitterP99Ms == 11)
    }

    @Test("Receiver loss deltas report first nonzero counters")
    func receiverLossDeltasReportFirstNonzeroCounters() {
        let feedback = MirageClientService.receiverTransportLossFeedback(
            currentIncompleteFrameTimeouts: 2,
            previousIncompleteFrameTimeouts: 0,
            currentForwardGapTimeouts: 1,
            previousForwardGapTimeouts: 0,
            currentMissingFragmentTimeouts: 4,
            previousMissingFragmentTimeouts: 0
        )

        #expect(feedback.lostFrameCount == 3)
        #expect(feedback.discardedPacketCount == 4)
    }

    @Test("Receiver loss deltas survive recovery feedback")
    func receiverLossDeltasSurviveRecoveryFeedback() {
        let loss = MirageClientService.receiverTransportLossFeedback(
            currentIncompleteFrameTimeouts: 5,
            previousIncompleteFrameTimeouts: 3,
            currentForwardGapTimeouts: 4,
            previousForwardGapTimeouts: 4,
            currentMissingFragmentTimeouts: 10,
            previousMissingFragmentTimeouts: 6
        )
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 13,
            sentAtUptime: 106,
            targetFPS: 60,
            recoveryState: .keyframeRecovery,
            recoveryCause: .frameLoss,
            transportLostFrameCount: loss.lostFrameCount,
            transportDiscardedPacketCount: loss.discardedPacketCount,
            metrics: metrics()
        )

        #expect(feedback.lostFrameCount == 2)
        #expect(feedback.discardedPacketCount == 4)
        #expect(feedback.recoveryState == .keyframeRecovery)
    }

    @Test("Receiver loss deltas ignore counter resets")
    func receiverLossDeltasIgnoreCounterResets() {
        let feedback = MirageClientService.receiverTransportLossFeedback(
            currentIncompleteFrameTimeouts: 1,
            previousIncompleteFrameTimeouts: 3,
            currentForwardGapTimeouts: 0,
            previousForwardGapTimeouts: 2,
            currentMissingFragmentTimeouts: 2,
            previousMissingFragmentTimeouts: 9
        )

        #expect(feedback.lostFrameCount == 0)
        #expect(feedback.discardedPacketCount == 0)
    }

    @Test("Audio sync pressure is included in receiver feedback")
    func audioSyncPressureIsIncludedInReceiverFeedback() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 9,
            sentAtUptime: 102,
            targetFPS: 60,
            recoveryState: .idle,
            audioDroppedFrameCount: 4,
            audioGateActive: true,
            metrics: metrics()
        )

        #expect(feedback.audioDroppedFrameCount == 4)
        #expect(feedback.audioGateActive == true)
    }

    @Test("Receiver feedback includes completed frame ACK ranges")
    func receiverFeedbackIncludesCompletedFrameAckRanges() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 10,
            sentAtUptime: 103,
            targetFPS: 60,
            recoveryState: .idle,
            ackRanges: [
                MediaFeedbackFrameRange(startFrame: 40, endFrame: 42),
                MediaFeedbackFrameRange(startFrame: 45, endFrame: 45)
            ],
            metrics: metrics()
        )

        #expect(feedback.ackRanges == [
            MediaFeedbackFrameRange(startFrame: 40, endFrame: 42),
            MediaFeedbackFrameRange(startFrame: 45, endFrame: 45)
        ])
    }

    @Test("Completed frame ACK ranges coalesce contiguous frames")
    func completedFrameAckRangesCoalesceContiguousFrames() {
        let ranges = FrameReassembler.completedFrameAckRanges(from: [10, 11, 12, 15, 16])

        #expect(ranges == [
            MediaFeedbackFrameRange(startFrame: 10, endFrame: 12),
            MediaFeedbackFrameRange(startFrame: 15, endFrame: 16)
        ])
    }

    @Test("Completed frame ACK ranges split at UInt32 wrap")
    func completedFrameAckRangesSplitAtUInt32Wrap() {
        let ranges = FrameReassembler.completedFrameAckRanges(
            from: [UInt32.max - 1, UInt32.max, 0, 1]
        )

        #expect(ranges == [
            MediaFeedbackFrameRange(startFrame: UInt32.max - 1, endFrame: UInt32.max),
            MediaFeedbackFrameRange(startFrame: 0, endFrame: 1)
        ])
    }

    @Test("P-frame timing samples are emitted only for completed P-frames")
    func pFrameTimingSamplesAreEmittedOnlyForCompletedPFrames() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 4)
        reassembler.setFrameHandler { _, _, _, _, _, _, release in
            release()
        }

        let keyframe = Data([0x10, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            keyframe,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 1,
                payload: keyframe,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )
        #expect(reassembler.consumePFrameTimingSamples().isEmpty)

        let pFrameFragment0 = Data([0x20, 0x00, 0x00, 0x00])
        reassembler.processPacket(
            pFrameFragment0,
            header: makeHeader(
                flags: [],
                frameNumber: 2,
                payload: pFrameFragment0,
                fragmentIndex: 0,
                fragmentCount: 2,
                frameByteCount: 8
            )
        )
        #expect(reassembler.consumePFrameTimingSamples().isEmpty)

        let pFrameFragment1 = Data([0x20, 0x01, 0x00, 0x00])
        reassembler.processPacket(
            pFrameFragment1,
            header: makeHeader(
                flags: [.endOfFrame],
                frameNumber: 2,
                payload: pFrameFragment1,
                fragmentIndex: 1,
                fragmentCount: 2,
                frameByteCount: 8
            )
        )

        let samples = reassembler.consumePFrameTimingSamples()
        #expect(samples.count == 1)
        #expect(samples.first?.frameNumber == 2)
        #expect((samples.first?.packetSpanMs ?? -1) >= 0)
        #expect((samples.first?.completionGapMs ?? -1) >= 0)
        #expect((samples.first?.completionAgeAtFeedbackMs ?? -1) >= 0)
        #expect((samples.first?.firstPacketGapMs ?? -1) >= 0)
    }

    @Test("Receiver feedback keeps newest 128 timing samples")
    func receiverFeedbackKeepsNewest128TimingSamples() {
        let samples = (0..<140).map {
            ReceiverPFrameTimingSample(
                frameNumber: UInt32($0),
                packetSpanMs: Double($0),
                completionGapMs: Double($0) + 1,
                completionAgeAtFeedbackMs: 0,
                firstPacketGapMs: Double($0) + 2
            )
        }
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 12,
            sentAtUptime: 105,
            targetFPS: 60,
            recoveryState: .idle,
            pFrameTimingSamples: samples,
            metrics: metrics()
        )

        #expect(feedback.pFrameTimingSamples.count == 128)
        #expect(feedback.pFrameTimingSamples.first?.frameNumber == 12)
        #expect(feedback.pFrameTimingSamples.last?.frameNumber == 139)
    }

    @Test("Receiver feedback metrics report aged receive gaps between frames")
    func receiverFeedbackMetricsReportAgedReceiveGapsBetweenFrames() {
        let tracker = ClientFrameMetricsTracker()

        tracker.recordReceivedFrame(now: 10)
        let activeSnapshot = tracker.snapshot(now: 10.35)
        let stalledSnapshot = tracker.snapshot(now: 11.25)

        #expect(activeSnapshot.receivedWorstGapMs >= 349)
        #expect(stalledSnapshot.receivedFPS == 0)
        #expect(stalledSnapshot.receivedWorstGapMs >= 1_249)
    }

    @Test("Stream metrics heartbeat can feed receiver feedback at stressed cadence")
    func streamMetricsHeartbeatCanFeedReceiverFeedbackAtStressedCadence() {
        #expect(StreamController.metricsDispatchInterval == .milliseconds(100))
    }

    private func metrics(
        droppedFrames: UInt64 = 0,
        decodeBacklogFrames: Int = 0,
        pendingFrameCount: Int = 0,
        smoothestTargetDelayMs: Double = 0,
        smoothestQueueDrops: UInt64 = 0,
        presentationStallCount: UInt64 = 0,
        pendingFrameNotReadyDisplayTickCount: UInt64 = 0,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0,
        receivedFrameIntervalP95Ms: Double = 20,
        receivedFrameIntervalP99Ms: Double = 35,
        receiverIngressJitterP95Ms: Double = 0,
        receiverIngressJitterP99Ms: Double = 0,
        reassemblerFrameCompletionLatencyP50Ms: Double = 0,
        reassemblerFrameCompletionLatencyP95Ms: Double = 0,
        reassemblerFrameCompletionLatencyMaxMs: Double = 0,
        reassemblerKeyframeCompletionLatencyP50Ms: Double = 0,
        reassemblerKeyframeCompletionLatencyP95Ms: Double = 0,
        reassemblerKeyframeCompletionLatencyMaxMs: Double = 0,
        reassemblerPFrameCompletionLatencyP50Ms: Double = 0,
        reassemblerPFrameCompletionLatencyP95Ms: Double = 0,
        reassemblerPFrameCompletionLatencyMaxMs: Double = 0
    ) -> StreamController.ClientFrameMetrics {
        StreamController.ClientFrameMetrics(
            decodedFPS: 24,
            receivedFPS: 60,
            receivedWorstGapMs: 80,
            receivedFrameIntervalP95Ms: receivedFrameIntervalP95Ms,
            receivedFrameIntervalP99Ms: receivedFrameIntervalP99Ms,
            receiverIngressJitterP95Ms: receiverIngressJitterP95Ms,
            receiverIngressJitterP99Ms: receiverIngressJitterP99Ms,
            droppedFrames: droppedFrames,
            decodeBacklogFrames: decodeBacklogFrames,
            decodeSubmissionLimit: 0,
            inFlightDecodeSubmissions: 0,
            displayTickFPS: 60,
            submitAttemptFPS: 60,
            layerAcceptedFPS: 55,
            visibleFrameFPS: 55,
            submittedFPS: 55,
            uniqueSubmittedFPS: 55,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: 30,
            smoothestDisplayDebtMs: 0,
            smoothestDisplayDebtCapMs: 0,
            smoothestTargetDelayMs: smoothestTargetDelayMs,
            overwrittenPendingFrames: 3,
            smoothestQueueDrops: smoothestQueueDrops,
            smoothestDisplayDebtDrops: 0,
            smoothestFifoResetCount: 0,
            smoothestDepthDrops: 0,
            smoothestAgeDrops: 0,
            smoothestDropsUnder100ms: 0,
            smoothestDroppedFrameAgeMaxMs: 0,
            lateFrameDrops: 2,
            displayLayerNotReadyCount: 8,
            repeatedFrameCount: 0,
            displayTickNoFrameCount: 0,
            pendingFrameNotReadyDisplayTickCount: pendingFrameNotReadyDisplayTickCount,
            missedVSyncCount: 4,
            displayTickIntervalP95Ms: 17,
            displayTickIntervalP99Ms: 20,
            playoutDelayFrames: 3,
            presentationStallCount: presentationStallCount,
            worstPresentationGapMs: 120,
            frameIntervalP95Ms: 20,
            frameIntervalP99Ms: 35,
            decodeHealthy: false,
            reassemblerPendingFrameCount: reassemblerPendingFrameCount,
            reassemblerPendingKeyframeCount: reassemblerPendingKeyframeCount,
            reassemblerPendingBytes: reassemblerPendingBytes,
            frameBufferPoolRetainedBytes: 2_000_000,
            reassemblerBudgetEvictions: reassemblerBudgetEvictions,
            reassemblerIncompleteFrameTimeouts: 0,
            reassemblerIncompleteFrameNoProgressTimeouts: 0,
            reassemblerIncompleteFrameLifetimeTimeouts: 0,
            reassemblerMissingFragmentTimeouts: 0,
            reassemblerForwardGapTimeouts: 0,
            reassemblerFrameCompletionLatencyP50Ms: reassemblerFrameCompletionLatencyP50Ms,
            reassemblerFrameCompletionLatencyP95Ms: reassemblerFrameCompletionLatencyP95Ms,
            reassemblerFrameCompletionLatencyMaxMs: reassemblerFrameCompletionLatencyMaxMs,
            reassemblerKeyframeCompletionLatencyP50Ms: reassemblerKeyframeCompletionLatencyP50Ms,
            reassemblerKeyframeCompletionLatencyP95Ms: reassemblerKeyframeCompletionLatencyP95Ms,
            reassemblerKeyframeCompletionLatencyMaxMs: reassemblerKeyframeCompletionLatencyMaxMs,
            reassemblerPFrameCompletionLatencyP50Ms: reassemblerPFrameCompletionLatencyP50Ms,
            reassemblerPFrameCompletionLatencyP95Ms: reassemblerPFrameCompletionLatencyP95Ms,
            reassemblerPFrameCompletionLatencyMaxMs: reassemblerPFrameCompletionLatencyMaxMs,
            reassemblerLatePFrameCompletionCount: 0,
            reassemblerFECRecoveredFragmentCount: 0,
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true
        )
    }
}
