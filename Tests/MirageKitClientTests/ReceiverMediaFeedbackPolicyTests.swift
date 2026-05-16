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

    @Test("Smoothest health treats target occupancy as healthy")
    func smoothestHealthTreatsTargetOccupancyAsHealthy() {
        let health = MirageClientService.smoothestLiveEdgeHealth(
            metrics: healthySmoothestMetrics(
                pendingFrameCount: 4,
                queueTargetDepth: 4,
                presentationMode: .hardCushion
            ),
            ingressMetrics: healthyIngressMetrics(),
            ingressDropDelta: 0,
            targetFPS: 60
        )

        #expect(health.healthyForLiveEdge)
        #expect(!health.requiresHardCushion)
    }

    @Test("Smoothest health ignores intentional catch-up drops")
    func smoothestHealthIgnoresIntentionalCatchUpDrops() {
        let health = MirageClientService.smoothestLiveEdgeHealth(
            metrics: healthySmoothestMetrics(
                pendingFrameCount: 1,
                smoothestQueueDrops: 3,
                smoothestCatchUpDrops: 3,
                queueTargetDepth: 1,
                presentationMode: .liveEdge
            ),
            ingressMetrics: healthyIngressMetrics(),
            ingressDropDelta: 0,
            targetFPS: 60
        )

        #expect(health.healthyForLiveEdge)
        #expect(!health.requiresHardCushion)
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
            smoothestAgeDrops: 0,
            smoothestCatchUpDrops: smoothestQueueDrops,
            smoothestCapacityDrops: 0,
            lateFrameDrops: 2,
            displayLayerNotReadyCount: 8,
            repeatedFrameCount: 0,
            displayTickNoFrameCount: 0,
            frameArrivedAfterNoFrameTickCount: 0,
            frameArrivalFallbackSubmittedCount: 0,
            missedVSyncCount: 4,
            displayTickIntervalP95Ms: 17,
            displayTickIntervalP99Ms: 20,
            playoutDelayFrames: 3,
            displaysImmediately: false,
            queueTargetDepth: 4,
            presentationMode: .hardCushion,
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
            reassemblerMissingFragmentTimeouts: 0,
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true,
            videoIngressMetrics: nil
        )
    }

    private func healthySmoothestMetrics(
        pendingFrameCount: Int,
        smoothestQueueDrops: UInt64 = 0,
        smoothestCatchUpDrops: UInt64 = 0,
        queueTargetDepth: Int,
        presentationMode: MiragePresentationDecisionMode
    ) -> StreamController.ClientFrameMetrics {
        StreamController.ClientFrameMetrics(
            decodedFPS: 60,
            receivedFPS: 60,
            receivedWorstGapMs: 18,
            receivedFrameIntervalP95Ms: 17,
            receivedFrameIntervalP99Ms: 18,
            droppedFrames: 0,
            displayTickFPS: 60,
            submitAttemptFPS: 60,
            layerAcceptedFPS: 60,
            presentedFPS: 60,
            submittedFPS: 60,
            uniqueSubmittedFPS: 60,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: 20,
            overwrittenPendingFrames: 0,
            smoothestQueueDrops: smoothestQueueDrops,
            smoothestAgeDrops: 0,
            smoothestCatchUpDrops: smoothestCatchUpDrops,
            smoothestCapacityDrops: 0,
            lateFrameDrops: 0,
            displayLayerNotReadyCount: 0,
            repeatedFrameCount: 0,
            displayTickNoFrameCount: 0,
            frameArrivedAfterNoFrameTickCount: 0,
            frameArrivalFallbackSubmittedCount: 0,
            missedVSyncCount: 0,
            displayTickIntervalP95Ms: 17,
            displayTickIntervalP99Ms: 18,
            playoutDelayFrames: 0,
            displaysImmediately: true,
            queueTargetDepth: queueTargetDepth,
            presentationMode: presentationMode,
            presentationStallCount: 0,
            worstPresentationGapMs: 0,
            frameIntervalP95Ms: 17,
            frameIntervalP99Ms: 18,
            decodeHealthy: true,
            activeJitterHoldMs: 0,
            reassemblerPendingFrameCount: 0,
            reassemblerPendingKeyframeCount: 0,
            reassemblerPendingBytes: 0,
            frameBufferPoolRetainedBytes: 0,
            reassemblerBudgetEvictions: 0,
            reassemblerIncompleteFrameTimeouts: 0,
            reassemblerMissingFragmentTimeouts: 0,
            decoderOutputPixelFormat: "420v",
            usingHardwareDecoder: true,
            videoIngressMetrics: nil
        )
    }

    private func healthyIngressMetrics() -> ClientVideoIngressMetricsSnapshot {
        ClientVideoIngressMetricsSnapshot(
            loomStreamDeliveryPPS: 600,
            loomStreamDeliveryIntervalMaxMs: 18,
            rawPacketIngressPPS: 600,
            incomingBatchRate: 600,
            incomingBatchIntervalP95Ms: 2,
            incomingBatchIntervalP99Ms: 3,
            incomingBatchIntervalMaxMs: 4,
            incomingBatchMaxSize: 1,
            incomingBatchAverageSize: 1,
            queuedBatchCount: 0,
            queuedPacketCount: 0,
            queueAgeMaxMs: 0,
            stalePacketDropCount: 0,
            overloadPacketDropCount: 0,
            processedPacketCount: 600,
            processorWakeDelayMaxMs: 2
        )
    }
}
