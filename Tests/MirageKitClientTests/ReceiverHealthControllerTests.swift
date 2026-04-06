//
//  ReceiverHealthControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Receiver Health Controller")
struct ReceiverHealthControllerTests {
    @Test("Severe transport pressure backs off immediately")
    func severeTransportPressureBacksOffImmediately() {
        var controller = MirageReceiverHealthController()
        let snapshot = severeTransportSnapshot()

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 10
        )

        #expect(action == .backoff(targetBitrateBps: 15_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Host degraded flags alone do not trigger backoff")
    func hostDegradedFlagsAloneDoNotTriggerBackoff() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostCurrentBitrate = 8_000_000
        snapshot.hostRequestedTargetBitrate = 80_000_000

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    @Test("Decode and presentation stalls alone do not trigger backoff")
    func decodeAndPresentationStallsAloneDoNotTriggerBackoff() {
        var controller = MirageReceiverHealthController()
        let snapshot = decodeStalledButTransportHealthySnapshot()

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    @Test("Decode stalls do not block upward probing when transport is healthy")
    func decodeStallsDoNotBlockUpwardProbingWhenTransportIsHealthy() {
        var controller = MirageReceiverHealthController()
        let snapshot = decodeStalledButTransportHealthySnapshot()

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )

        #expect(secondAction == .probe(targetBitrateBps: 100_000_000))
    }

    @Test("Healthy fast-start windows probe upward after two clean samples")
    func healthyFastStartWindowsProbeUpwardAfterTwoCleanSamples() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.62)

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )

        #expect(firstAction == .none)
        #expect(secondAction == .probe(targetBitrateBps: 100_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Probes stay bounded by the configured ceiling")
    func probesStayBoundedByTheConfiguredCeiling() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.55)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 90_000_000,
            ceilingBps: 100_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 90_000_000,
            ceilingBps: 100_000_000,
            now: 2
        )

        #expect(probe == .probe(targetBitrateBps: 100_000_000))
    }

    @Test("Healthy samples can probe above the old quality stop when source headroom remains")
    func healthySamplesProbeAboveLegacyQualityStop() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.85)
        snapshot.hostCaptureIngressFPS = 60
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 60
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 12

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 350_000_000,
            ceilingBps: 500_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 350_000_000,
            ceilingBps: 500_000_000,
            now: 2
        )

        #expect(probe == .probe(targetBitrateBps: 472_500_000))
    }

    @Test("Healthy transport still probes upward when host encode is already over budget")
    func healthyTransportStillProbesWhenHostEncodeIsOverBudget() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostCaptureIngressFPS = 60
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 42
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 21

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 220_000_000,
            ceilingBps: 500_000_000,
            now: 0
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 220_000_000,
            ceilingBps: 500_000_000,
            now: 2
        )

        #expect(action == .probe(targetBitrateBps: 300_000_000))
    }

    @Test("Source-paced low cadence still probes upward when transport is healthy")
    func sourcePacedLowCadenceStillProbesUpwardWhenTransportIsHealthy() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostCaptureIngressFPS = 44
        snapshot.hostCaptureFPS = 43
        snapshot.hostEncodeAttemptFPS = 43
        snapshot.hostEncodedFPS = 43
        snapshot.receivedFPS = 43
        snapshot.decodedFPS = 43
        snapshot.presentedFPS = 43
        snapshot.uniquePresentedFPS = 43

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 0
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 2
        )

        #expect(action == .probe(targetBitrateBps: 128_000_000))
    }

    @Test("Minor delivery drift still probes upward when transport is otherwise clean")
    func minorDeliveryDriftStillProbesUpwardWhenTransportIsOtherwiseClean() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostEncodedFPS = 60
        snapshot.receivedFPS = 58
        snapshot.decodedFPS = 58
        snapshot.presentedFPS = 58
        snapshot.uniquePresentedFPS = 58

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 24_000_000,
            ceilingBps: 136_000_000,
            now: 0
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 24_000_000,
            ceilingBps: 136_000_000,
            now: 2
        )

        #expect(action == .probe(targetBitrateBps: 104_000_000))
    }

    @Test("Transport drops trigger backoff even when decode metrics look healthy")
    func transportDropsTriggerBackoffEvenWhenDecodeLooksHealthy() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostStalePacketDrops = 12

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )

        #expect(action == .backoff(targetBitrateBps: 15_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Sustained severe transport stress keeps stepping bitrate downward")
    func sustainedSevereTransportStressKeepsSteppingBitrateDownward() {
        var controller = MirageReceiverHealthController()
        let snapshot = severeTransportSnapshot()

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 0
        )
        let cooldownAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 1
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 3
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(cooldownAction == .none)
        #expect(secondAction == .backoff(targetBitrateBps: 11_250_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Healthy windows resume probing after a transient severe transport backoff")
    func healthyWindowsResumeProbingAfterTransientSevereTransportBackoff() {
        var controller = MirageReceiverHealthController()
        let stressedSnapshot = severeTransportSnapshot()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)

        let firstAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 200_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 2
        )
        let thirdAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 4
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(secondAction == .none)
        #expect(thirdAction == .probe(targetBitrateBps: 95_000_000))
        #expect(controller.state == .stable)
    }

    private func healthySnapshot(activeQuality: Double) -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            presentedFPS: 60,
            uniquePresentedFPS: 60,
            renderBufferDepth: 0,
            decodeHealthy: true,
            hostActiveQuality: activeQuality,
            hostTargetFrameRate: 60,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 0
        snapshot.hostSendStartDelayAverageMs = 0
        snapshot.hostSendCompletionAverageMs = 0
        snapshot.hostPacketPacerAverageSleepMs = 0
        snapshot.hostStalePacketDrops = 0
        snapshot.hostGenerationAbortDrops = 0
        snapshot.hostNonKeyframeHoldDrops = 0
        snapshot.hostCaptureIngressFPS = 60
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 60
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 10
        return snapshot
    }

    private func severeTransportSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.receivedFPS = 30
        snapshot.hostSendQueueBytes = 2_500_000
        snapshot.hostSendStartDelayAverageMs = 7
        snapshot.hostSendCompletionAverageMs = 30
        snapshot.hostPacketPacerAverageSleepMs = 2.5
        snapshot.hostStalePacketDrops = 12
        return snapshot
    }

    private func decodeStalledButTransportHealthySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.decodedFPS = 0
        snapshot.presentedFPS = 0
        snapshot.uniquePresentedFPS = 0
        snapshot.decodeHealthy = false
        return snapshot
    }
}
#endif
