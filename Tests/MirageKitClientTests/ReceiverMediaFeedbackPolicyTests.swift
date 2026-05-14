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
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true
        )
    }
}
