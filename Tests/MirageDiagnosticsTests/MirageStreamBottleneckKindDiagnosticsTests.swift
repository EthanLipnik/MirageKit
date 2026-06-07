//
//  MirageStreamBottleneckKindDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageDiagnostics
import Testing

#if os(macOS)
@Suite("Stream Bottleneck Kind Diagnostics")
struct MirageStreamBottleneckKindDiagnosticsTests {
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
        snapshot.submittedFPS = 42
        snapshot.uniqueSubmittedFPS = 42
        snapshot.clientPresentedFPS = 42
        snapshot.hostSendQueueBytes = 1_200_000
        snapshot.hostSendStartDelayAverageMs = 3

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
        snapshot.submittedFPS = 8
        snapshot.uniqueSubmittedFPS = 8
        snapshot.clientPresentedFPS = 8

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
        snapshot.submittedFPS = 38
        snapshot.uniqueSubmittedFPS = 38
        snapshot.clientPresentedFPS = 38

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Presentation-bound classification prefers render backpressure with healthy decode")
    func presentationBoundClassificationPrefersRenderBackpressure() {
        var snapshot = baselineSnapshot()
        snapshot.submittedFPS = 44
        snapshot.uniqueSubmittedFPS = 44
        snapshot.clientPresentedFPS = 44
        snapshot.clientPendingFrameAgeMs = 28
        snapshot.clientOverwrittenPendingFrames = 3

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Presentation-bound classification uses uneven submit cadence")
    func presentationBoundClassificationUsesUnevenSubmitCadence() {
        var snapshot = baselineSnapshot()
        snapshot.submittedFPS = 56
        snapshot.uniqueSubmittedFPS = 56
        snapshot.clientPresentedFPS = 56
        snapshot.clientFrameIntervalP99Ms = 55
        snapshot.clientWorstPresentationGapMs = 95

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Presentation-bound classification catches severe cadence spikes near target FPS")
    func presentationBoundClassificationCatchesSevereCadenceSpikesNearTargetFPS() {
        var snapshot = baselineSnapshot()
        snapshot.submittedFPS = 59
        snapshot.uniqueSubmittedFPS = 59
        snapshot.clientPresentedFPS = 59
        snapshot.clientFrameIntervalP99Ms = 151

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Healthy decode and display ticks avoid presentation-bound classification without layer backpressure")
    func healthyDecodeAndDisplayTicksAvoidPresentationBoundWithoutLayerBackpressure() {
        var snapshot = baselineSnapshot()
        snapshot.clientDisplayTickFPS = 60
        snapshot.submittedFPS = 50
        snapshot.uniqueSubmittedFPS = 50
        snapshot.clientPresentedFPS = 50
        snapshot.clientFrameIntervalP99Ms = 120
        snapshot.clientWorstPresentationGapMs = 220
        snapshot.clientDisplayLayerNotReadyCount = 0

        #expect(snapshot.bottleneckKind != .presentationBound)
    }

    @Test("Client render pressure is not classified as network-bound on clean transport")
    func clientRenderPressureIsNotNetworkBoundOnCleanTransport() {
        var snapshot = baselineSnapshot()
        snapshot.clientPresentedFPS = 24
        snapshot.clientWorstPresentationGapMs = 120
        snapshot.clientFrameIntervalP99Ms = 70
        snapshot.clientRepeatedDeliveredSourceFrameCount = 8
        snapshot.clientReceivedWorstGapMs = 120

        #expect(snapshot.bottleneckKind == .presentationBound)
    }

    @Test("Renderer enqueue cadence alone is not visible progress")
    func rendererEnqueueCadenceAloneIsNotVisibleProgress() {
        var snapshot = baselineSnapshot()
        snapshot.clientPresentedFPS = 0
        snapshot.submittedFPS = 60
        snapshot.uniqueSubmittedFPS = 60

        #expect(snapshot.bottleneckKind == .unknown)
    }

    @Test("Decode backlog classification stays client-bound on clean transport")
    func decodeBacklogClassificationStaysClientBoundOnCleanTransport() {
        var snapshot = baselineSnapshot()
        snapshot.decodedFPS = 42
        snapshot.submittedFPS = 42
        snapshot.uniqueSubmittedFPS = 42
        snapshot.clientPresentedFPS = 42
        snapshot.clientDecodeBacklogFrameCount = 4

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
        snapshot.submittedFPS = 0
        snapshot.uniqueSubmittedFPS = 0
        snapshot.clientPresentedFPS = 0
        snapshot.clientPresentedFPS = 0
        snapshot.decodeHealthy = false
        snapshot.clientReceivedWorstGapMs = 556
        snapshot.clientReceivedWorstGapMs = 556

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
        snapshot.submittedFPS = 44
        snapshot.uniqueSubmittedFPS = 44
        snapshot.clientPresentedFPS = 42
        snapshot.clientPresentedFPS = 42
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
        snapshot.submittedFPS = 44
        snapshot.uniqueSubmittedFPS = 44
        snapshot.clientPresentedFPS = 42
        snapshot.clientPresentedFPS = 42
        snapshot.decodeHealthy = false

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Clearly named cadence aliases route to existing telemetry")
    func clearlyNamedCadenceAliasesRouteToExistingTelemetry() {
        var snapshot = baselineSnapshot()
        snapshot.submittedFPS = 42
        snapshot.uniqueSubmittedFPS = 39
        snapshot.clientPresentedFPS = 37
        snapshot.clientRepeatedDeliveredSourceFrameCount = 3
        snapshot.clientRepeatedFrameCount = 5
        snapshot.clientDisplayTickFPS = 120
        snapshot.pendingFrameCount = 2
        snapshot.clientDecodeBacklogFrameCount = 4

        #expect(snapshot.submittedFPS == 42)
        #expect(snapshot.uniqueSubmittedFPS == 39)
        #expect(snapshot.clientPresentedFPS == 37)
        #expect(snapshot.clientPresentedFPS > 0)
        #expect(snapshot.clientRepeatedDeliveredSourceFrameCount == 3)
        #expect(snapshot.clientRepeatedFrameCount == 5)
        #expect(snapshot.clientDisplayTickFPS == 120)
        #expect(snapshot.pendingFrameCount == 2)
        #expect(snapshot.clientDecodeBacklogFrameCount == 4)
    }

    @Test("Host cadence pressure wins over presentation symptoms")
    func hostCadencePressureWinsOverPresentationSymptoms() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureIngressFPS = 42
        snapshot.hostCaptureFPS = 42
        snapshot.hostEncodeAttemptFPS = 42
        snapshot.hostEncodedFPS = 42
        snapshot.submittedFPS = 44
        snapshot.uniqueSubmittedFPS = 44
        snapshot.clientPresentedFPS = 44
        snapshot.clientDisplayLayerNotReadyCount = 2

        #expect(snapshot.bottleneckKind == .hostCadenceLimited)
    }

    private func baselineSnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            clientPresentedFPS: 60,
            submittedFPS: 60,
            uniqueSubmittedFPS: 60,
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
