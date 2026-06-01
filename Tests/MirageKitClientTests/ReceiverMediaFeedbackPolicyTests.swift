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
    @Test("Receiver feedback rejects legacy payloads without timing samples")
    func receiverFeedbackRejectsLegacyPayloadsWithoutTimingSamples() throws {
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

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReceiverMediaFeedbackMessage.self, from: payload)
        }
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
            presentationQueueDepth: 1,
            metrics: metrics()
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
        #expect(decoded.presentationQueueDepth == 1)
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
        #expect(feedback.presentationBacklogFrames == 5)
        #expect(feedback.recoveryState == .keyframeRecovery)
        #expect(feedback.recoveryCause == .frameLoss)
        #expect(feedback.reliabilityCauses.contains(.keyframeStarvation))
        #expect(feedback.reliabilityCauses.contains(.memoryPressure))
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
        smoothestQueueDrops: UInt64 = 0,
        presentationStallCount: UInt64 = 0,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0
    ) -> StreamController.ClientFrameMetrics {
        StreamController.ClientFrameMetrics(
            decodedFPS: 24,
            receivedFPS: 60,
            receivedWorstGapMs: 80,
            receivedFrameIntervalP95Ms: 20,
            receivedFrameIntervalP99Ms: 35,
            droppedFrames: droppedFrames,
            decodeBacklogFrames: decodeBacklogFrames,
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
            smoothestTargetDelayMs: 0,
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
            missedVSyncCount: 4,
            displayTickIntervalP95Ms: 17,
            displayTickIntervalP99Ms: 20,
            playoutDelayFrames: 3,
            presentationStallCount: presentationStallCount,
            worstPresentationGapMs: 120,
            frameIntervalP95Ms: 20,
            frameIntervalP99Ms: 35,
            decodeHealthy: false,
            activeJitterHoldMs: 50,
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
            reassemblerPFrameCompletionLatencyP50Ms: 0,
            reassemblerPFrameCompletionLatencyP95Ms: 0,
            reassemblerPFrameCompletionLatencyMaxMs: 0,
            reassemblerLatePFrameCompletionCount: 0,
            reassemblerFECRecoveredFragmentCount: 0,
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true
        )
    }
}
