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
    @Test("Capture-bound classification prefers missing host capture cadence")
    func captureBoundClassificationPrefersMissingHostCaptureCadence() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureIngressFPS = 42
        snapshot.hostCaptureFPS = 42
        snapshot.hostEncodeAttemptFPS = 42
        snapshot.hostEncodedFPS = 42

        #expect(snapshot.bottleneckKind == .captureBound)
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
        snapshot.presentedFPS = 42
        snapshot.uniquePresentedFPS = 42
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

    @Test("Decode-bound classification prefers client decode lag when transport is clean")
    func decodeBoundClassificationPrefersClientDecodeLag() {
        var snapshot = baselineSnapshot()
        snapshot.decodeHealthy = false
        snapshot.decodedFPS = 38
        snapshot.presentedFPS = 38
        snapshot.uniquePresentedFPS = 38

        #expect(snapshot.bottleneckKind == .decodeBound)
    }

    @Test("Mixed classification reports multiple active constraints")
    func mixedClassificationReportsMultipleActiveConstraints() {
        var snapshot = baselineSnapshot()
        snapshot.hostCaptureIngressFPS = 42
        snapshot.hostCaptureFPS = 42
        snapshot.hostEncodeAttemptFPS = 42
        snapshot.hostEncodedFPS = 42
        snapshot.hostSendQueueBytes = 1_200_000

        #expect(snapshot.bottleneckKind == .mixed)
    }

    private func baselineSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            presentedFPS: 60,
            uniquePresentedFPS: 60,
            renderBufferDepth: 0,
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
