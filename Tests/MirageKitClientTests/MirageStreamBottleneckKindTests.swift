//
//  MirageStreamBottleneckKindTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Mirage Stream Bottleneck Kind")
struct MirageStreamBottleneckKindTests {
    @Test("Host cadence classification prefers missing host capture cadence")
    func hostCadenceClassificationPrefersMissingHostCaptureCadence() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureIngressFPS = 42
        snapshot.hostCaptureFPS = 42
        snapshot.hostEncodeAttemptFPS = 42
        snapshot.hostEncodedFPS = 42

        #expect(snapshot.bottleneckKind == .hostCadenceLimited)
    }

    @Test("Host cadence classification uses capture gap telemetry")
    func hostCadenceClassificationUsesCaptureGapTelemetry() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureDeliveredFrameGapP99Ms = 55
        snapshot.hostCaptureDeliveredFrameGapWorstMs = 95

        #expect(snapshot.bottleneckKind == .hostCadenceLimited)
    }

    @Test("Encode-bound classification prefers encode throughput behind healthy source cadence")
    func encodeBoundClassificationPrefersEncodeThroughputBehindHealthySourceCadence() {
        var snapshot = baselineSnapshot()
        snapshot.hostAverageEncodeMs = 21
        snapshot.hostEncodedFPS = 38

        #expect(snapshot.bottleneckKind == .encodeBound)
    }

    @Test("Network-bound classification prefers transport pressure")
    func networkBoundClassificationPrefersTransportPressure() {
        var snapshot = baselineSnapshot()
        snapshot.receivedFPS = 42
        snapshot.decodedFPS = 42
        snapshot.layerEnqueueFPS = 42
        snapshot.uniqueLayerEnqueueFPS = 42
        snapshot.clientVisibleFrameFPS = 42
        snapshot.hostSendQueueBytes = 1_200_000
        snapshot.hostSendStartDelayAverageMs = 3

        #expect(snapshot.bottleneckKind == .networkBound)
    }

    @Test("Transport admission pacing classifies as network-bound")
    func transportAdmissionPacingClassifiesAsNetworkBound() {
        var snapshot = baselineSnapshot()
        snapshot.hostEncodedFPS = 30
        snapshot.hostEncodeAttemptFPS = 30
        snapshot.receivedFPS = 30
        snapshot.decodedFPS = 30
        snapshot.layerEnqueueFPS = 30
        snapshot.uniqueLayerEnqueueFPS = 30
        snapshot.clientVisibleFrameFPS = 30
        snapshot.hostTransportAdmissionSkips = 30
        snapshot.hostTransportAdmissionActiveHoldMs = 750

        #expect(snapshot.bottleneckKind == .networkBound)
    }

    @Test("Clean transport window clears prior network-bound classification inputs")
    func cleanTransportWindowClearsPriorNetworkBoundClassificationInputs() {
        var stressedSnapshot = baselineSnapshot()
        stressedSnapshot.hostStalePacketDrops = 12
        #expect(stressedSnapshot.bottleneckKind == .networkBound)

        let recoveredSnapshot = baselineSnapshot()
        #expect(recoveredSnapshot.bottleneckKind != .networkBound)
    }

    @Test("Delay-only transport advisory is not network-bound")
    func delayOnlyTransportAdvisoryIsNotNetworkBound() {
        var snapshot = baselineSnapshot()
        snapshot.hostSendStartDelayAverageMs = 3
        snapshot.hostSendCompletionAverageMs = 14

        #expect(snapshot.bottleneckKind != .networkBound)
    }

    @Test("Delivery cadence loss alone is not network-bound")
    func deliveryCadenceLossAloneIsNotNetworkBound() {
        var snapshot = baselineSnapshot()
        snapshot.receivedFPS = 8
        snapshot.decodedFPS = 8
        snapshot.layerEnqueueFPS = 8
        snapshot.uniqueLayerEnqueueFPS = 8
        snapshot.clientVisibleFrameFPS = 8

        #expect(snapshot.bottleneckKind != .networkBound)
    }

    @Test("Packet pacer pressure alone is not network-bound")
    func packetPacerPressureAloneIsNotNetworkBound() {
        var snapshot = baselineSnapshot()
        snapshot.hostPacketPacerAverageSleepMs = 1.0

        #expect(snapshot.bottleneckKind != .networkBound)
    }

    @Test("Decode-bound classification prefers client decode lag when transport is clean")
    func decodeBoundClassificationPrefersClientDecodeLag() {
        var snapshot = baselineSnapshot()
        snapshot.decodeHealthy = false
        snapshot.decodedFPS = 38
        snapshot.layerEnqueueFPS = 38
        snapshot.uniqueLayerEnqueueFPS = 38
        snapshot.clientVisibleFrameFPS = 38

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Presentation-bound classification prefers render backpressure with healthy decode")
    func presentationBoundClassificationPrefersRenderBackpressure() {
        var snapshot = baselineSnapshot()
        snapshot.layerEnqueueFPS = 44
        snapshot.uniqueLayerEnqueueFPS = 44
        snapshot.clientVisibleFrameFPS = 44
        snapshot.clientPendingFrameAgeMs = 28
        snapshot.clientOverwrittenPendingFrames = 3

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Presentation-bound classification uses uneven submit cadence")
    func presentationBoundClassificationUsesUnevenSubmitCadence() {
        var snapshot = baselineSnapshot()
        snapshot.layerEnqueueFPS = 56
        snapshot.uniqueLayerEnqueueFPS = 56
        snapshot.clientVisibleFrameFPS = 56
        snapshot.clientFrameIntervalP99Ms = 55
        snapshot.clientWorstPresentationGapMs = 95

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Presentation-bound classification catches severe cadence spikes near target FPS")
    func presentationBoundClassificationCatchesSevereCadenceSpikesNearTargetFPS() {
        var snapshot = baselineSnapshot()
        snapshot.layerEnqueueFPS = 59
        snapshot.uniqueLayerEnqueueFPS = 59
        snapshot.clientVisibleFrameFPS = 59
        snapshot.clientFrameIntervalP99Ms = 151

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Healthy decode and display ticks avoid presentation-bound classification without layer backpressure")
    func healthyDecodeAndDisplayTicksAvoidPresentationBoundWithoutLayerBackpressure() {
        var snapshot = baselineSnapshot()
        snapshot.clientDisplayTickFPS = 60
        snapshot.layerEnqueueFPS = 50
        snapshot.uniqueLayerEnqueueFPS = 50
        snapshot.clientVisibleFrameFPS = 50
        snapshot.clientFrameIntervalP99Ms = 120
        snapshot.clientWorstPresentationGapMs = 220
        snapshot.clientDisplayLayerNotReadyCount = 0

        #expect(snapshot.bottleneckKind != .presentationBound)
    }

    @Test("Client render pressure is not classified as network-bound on clean transport")
    func clientRenderPressureIsNotNetworkBoundOnCleanTransport() {
        var snapshot = baselineSnapshot()
        snapshot.clientVisibleFrameFPS = 24
        snapshot.clientVisibleWorstPresentationGapMs = 120
        snapshot.clientVisibleFrameIntervalP99Ms = 70
        snapshot.clientRepeatedDeliveredSourceFrameCount = 8
        snapshot.clientIncomingMediaBatchIntervalMaxMs = 120

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Renderer enqueue cadence alone is not visible progress")
    func rendererEnqueueCadenceAloneIsNotVisibleProgress() {
        var snapshot = baselineSnapshot()
        snapshot.clientDeliveredSourceFrameCadenceKnown = false
        snapshot.clientUniqueDeliveredSourceFrameFPS = 0
        snapshot.clientRendererEnqueueFPS = 60
        snapshot.clientUniqueRendererEnqueueFPS = 60

        #expect(snapshot.bottleneckKind == .unknown)
    }

    @Test("Decode backlog classification stays client-bound on clean transport")
    func decodeBacklogClassificationStaysClientBoundOnCleanTransport() {
        var snapshot = baselineSnapshot()
        snapshot.decodedFPS = 42
        snapshot.clientRendererEnqueueFPS = 42
        snapshot.clientUniqueRendererEnqueueFPS = 42
        snapshot.clientUniqueDeliveredSourceFrameFPS = 42
        snapshot.clientDecodeQueueBacklogFrames = 4
        snapshot.clientDecodeSubmissionInFlightCount = 2
        snapshot.clientDecodeSubmissionLimit = 2

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Decode recovery collapse stays client-bound on clean transport")
    func decodeRecoveryCollapseStaysClientBoundOnCleanTransport() {
        var snapshot = baselineSnapshot()
        snapshot.hostTargetFrameRate = 120
        snapshot.hostFrameBudgetMs = 8.33
        snapshot.hostAverageEncodeMs = 6
        snapshot.hostCaptureIngressFPS = 120
        snapshot.hostCaptureFPS = 120
        snapshot.hostEncodeAttemptFPS = 120
        snapshot.hostEncodedFPS = 120
        snapshot.receivedFPS = 0
        snapshot.decodedFPS = 0
        snapshot.clientRendererEnqueueFPS = 0
        snapshot.clientUniqueRendererEnqueueFPS = 0
        snapshot.clientUniqueDeliveredSourceFrameFPS = 0
        snapshot.clientVisibleFrameFPS = 0
        snapshot.decodeHealthy = false
        snapshot.clientReceivedWorstGapMs = 556
        snapshot.clientIncomingMediaBatchIntervalMaxMs = 556

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Above-target host encode does not hide client decode deficit")
    func equalReceivedAndDecodedCadenceIsNotDecodeBound() {
        var snapshot = baselineSnapshot()
        snapshot.hostTargetFrameRate = 60
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 10
        snapshot.hostCaptureIngressFPS = 120.4
        snapshot.hostCaptureFPS = 120.4
        snapshot.hostEncodeAttemptFPS = 119.9
        snapshot.hostEncodedFPS = 81.2
        snapshot.receivedFPS = 44
        snapshot.decodedFPS = 44
        snapshot.clientRendererEnqueueFPS = 44
        snapshot.clientUniqueRendererEnqueueFPS = 44
        snapshot.clientUniqueDeliveredSourceFrameFPS = 42
        snapshot.clientVisibleFrameFPS = 42
        snapshot.decodeHealthy = false

        #expect(snapshot.bottleneckKind != .decodeBound)
    }

    @Test("Above-target host encode does not hide client decode lag")
    func aboveTargetHostEncodeDoesNotHideClientDecodeLag() {
        var snapshot = baselineSnapshot()
        snapshot.hostTargetFrameRate = 60
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 10
        snapshot.hostCaptureIngressFPS = 120.4
        snapshot.hostCaptureFPS = 120.4
        snapshot.hostEncodeAttemptFPS = 119.9
        snapshot.hostEncodedFPS = 81.2
        snapshot.receivedFPS = 58
        snapshot.decodedFPS = 44
        snapshot.clientRendererEnqueueFPS = 44
        snapshot.clientUniqueRendererEnqueueFPS = 44
        snapshot.clientUniqueDeliveredSourceFrameFPS = 42
        snapshot.clientVisibleFrameFPS = 42
        snapshot.decodeHealthy = false

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Clearly named cadence aliases route to existing telemetry")
    func clearlyNamedCadenceAliasesRouteToExistingTelemetry() {
        var snapshot = baselineSnapshot()
        snapshot.clientRendererEnqueueFPS = 42
        snapshot.clientUniqueRendererEnqueueFPS = 39
        snapshot.clientUniqueDeliveredSourceFrameFPS = 37
        snapshot.clientDeliveredSourceFrameCadenceKnown = true
        snapshot.clientRepeatedDeliveredSourceFrameCount = 3
        snapshot.clientRepeatedDisplayTickFrameCount = 5
        snapshot.clientDisplayRefreshTickFPS = 120
        snapshot.clientRenderQueueBacklogFrames = 2
        snapshot.clientDecodeQueueBacklogFrames = 4

        #expect(snapshot.layerEnqueueFPS == 42)
        #expect(snapshot.uniqueLayerEnqueueFPS == 39)
        #expect(snapshot.clientVisibleFrameFPS == 37)
        #expect(snapshot.clientVisibleFrameCadenceKnown)
        #expect(snapshot.clientRepeatedSourceFrameCount == 3)
        #expect(snapshot.clientRepeatedFrameCount == 5)
        #expect(snapshot.clientDisplayTickFPS == 120)
        #expect(snapshot.clientUnsubmittedPendingFrameCount == 2)
        #expect(snapshot.clientDecodeBacklogFrames == 4)
    }

    @Test("Host cadence pressure wins over presentation symptoms")
    func hostCadencePressureWinsOverPresentationSymptoms() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureIngressFPS = 42
        snapshot.hostCaptureFPS = 42
        snapshot.hostEncodeAttemptFPS = 42
        snapshot.hostEncodedFPS = 42
        snapshot.layerEnqueueFPS = 44
        snapshot.uniqueLayerEnqueueFPS = 44
        snapshot.clientVisibleFrameFPS = 44
        snapshot.clientDisplayLayerNotReadyCount = 2

        #expect(snapshot.bottleneckKind == .hostCadenceLimited)
    }

    private func baselineSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            layerEnqueueFPS: 60,
            uniqueLayerEnqueueFPS: 60,
            clientVisibleFrameFPS: 60,
            clientVisibleFrameCadenceKnown: true,
            pendingFrameCount: 0,
            decodeHealthy: true,
            hostEncodedFPS: 60,
            hostActiveQuality: 0.85,
            hostTargetFrameRate: 60,
            hostFrameBudgetMs: 16.67,
            hostAverageEncodeMs: 12,
            hostCaptureIngressFPS: 60,
            hostCaptureFPS: 60,
            hostEncodeAttemptFPS: 60,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 0
        snapshot.hostSendStartDelayAverageMs = 0
        snapshot.hostSendCompletionAverageMs = 0
        snapshot.hostPacketPacerAverageSleepMs = 0
        snapshot.hostStalePacketDrops = 0
        snapshot.hostGenerationAbortDrops = 0
        snapshot.hostNonKeyframeHoldDrops = 0
        return snapshot
    }
}
#endif
