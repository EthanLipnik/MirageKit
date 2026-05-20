//
//  ReceiverMediaFeedbackPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Receiver Media Feedback Policy")
struct ReceiverMediaFeedbackPolicyTests {
    @Test("Receiver feedback decodes legacy payloads without optional latency fields")
    func receiverFeedbackDecodesLegacyPayloadsWithoutOptionalLatencyFields() throws {
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

        #expect(feedback.pFrameCompletionLatencyP95Ms == nil)
        #expect(feedback.latePFrameCount == nil)
        #expect(feedback.reliabilityCauses.isEmpty)
    }

    @Test("Local render and reassembly symptoms are not reported as transport loss")
    func localPipelineSymptomsAreNotReportedAsTransportLoss() {
        let feedback = MirageClientService.makeReceiverMediaFeedback(
            streamID: 1,
            sequence: 7,
            sentAtUptime: 100,
            targetFPS: 60,
            recoveryState: .keyframeRecovery,
            metrics: metrics(
                droppedFrames: 42,
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
        #expect(feedback.presentationBacklogFrames == 5)
        #expect(feedback.recoveryState == .keyframeRecovery)
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

    private func metrics(
        droppedFrames: UInt64 = 0,
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
            displayTickFPS: 60,
            submitAttemptFPS: 60,
            layerAcceptedFPS: 55,
            presentedFPS: 55,
            submittedFPS: 55,
            uniqueSubmittedFPS: 55,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: 30,
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
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true
        )
    }
}
