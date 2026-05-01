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

    @Test("Presentation-bound samples remain transport-clean")
    func presentationBoundSamplesRemainTransportClean() {
        var controller = MirageReceiverHealthController()
        let snapshot = presentationBoundButTransportHealthySnapshot()

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

        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Decode-bound samples remain transport-clean")
    func decodeBoundSamplesRemainTransportClean() {
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

        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
    }

    @Test("Delay-only bursts do not trigger backoff or block probing")
    func delayOnlyBurstsDoNotTriggerBackoffOrBlockProbing() {
        var controller = MirageReceiverHealthController()
        let snapshot = delayOnlyBurstSnapshot()

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
        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Packet pacer pressure alone does not trigger backoff or block probing")
    func packetPacerPressureAloneDoesNotTriggerBackoffOrBlockProbing() {
        var controller = MirageReceiverHealthController()
        let snapshot = packetPacerOnlySnapshot()

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
        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
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
        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Successful probe cooldowns climb in bounded steps")
    func successfulProbeCooldownsClimbInBoundedSteps() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.62)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let firstProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        controller.noteProbeSucceeded(now: 2)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 5
        )
        let cooldownAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 5.5
        )
        let secondProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 6
        )

        #expect(firstProbe == .probe(targetBitrateBps: 32_000_000))
        #expect(cooldownAction == .none)
        #expect(secondProbe == .probe(targetBitrateBps: 44_000_000))
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

        #expect(probe == .probe(targetBitrateBps: 382_000_000))
    }

    @Test("Encode-bound samples remain transport-clean")
    func encodeBoundSamplesRemainTransportClean() {
        var controller = MirageReceiverHealthController()
        let snapshot = encodeBoundButTransportHealthySnapshot()

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

        #expect(action == .probe(targetBitrateBps: 252_000_000))
    }

    @Test("Host-cadence-limited samples remain transport-clean but do not probe upward")
    func hostCadenceLimitedSamplesRemainTransportCleanWithoutProbing() {
        var controller = MirageReceiverHealthController()
        let snapshot = captureBoundButTransportHealthySnapshot()

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

        #expect(action == .none)
    }

    @Test("Mixed-bound samples remain transport-clean")
    func mixedBoundSamplesRemainTransportClean() {
        var controller = MirageReceiverHealthController()
        let snapshot = mixedBoundButTransportHealthySnapshot()

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

        #expect(action == .probe(targetBitrateBps: 60_000_000))
    }

    @Test("Delivery cadence collapse without transport pressure does not back off")
    func deliveryCadenceCollapseWithoutTransportPressureDoesNotBackOff() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.receivedFPS = 4
        snapshot.decodedFPS = 4
        snapshot.submittedFPS = 4
        snapshot.uniqueSubmittedFPS = 4

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    @Test("Local generation and keyframe hold drops do not trigger transport backoff")
    func localGenerationAndKeyframeHoldDropsDoNotTriggerTransportBackoff() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostGenerationAbortDrops = 40
        snapshot.hostNonKeyframeHoldDrops = 40

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    @Test("Minor delivery drift still probes upward when transport is otherwise clean")
    func minorDeliveryDriftStillProbesUpwardWhenTransportIsOtherwiseClean() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostEncodedFPS = 60
        snapshot.receivedFPS = 58
        snapshot.decodedFPS = 58
        snapshot.submittedFPS = 58
        snapshot.uniqueSubmittedFPS = 58

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

        #expect(action == .probe(targetBitrateBps: 36_000_000))
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

    @Test("Local recovery holds the learned ceiling after a transient severe transport backoff")
    func localRecoveryHoldsLearnedCeilingAfterTransientSevereTransportBackoff() {
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
        let delayedRecoveryAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 12
        )
        controller.noteProbeSucceeded(now: 12)
        for time in stride(from: 13.0, through: 19.0, by: 1.0) {
            _ = controller.advance(
                snapshots: [healthySnapshot],
                currentBitrateBps: 17_000_000,
                ceilingBps: 200_000_000,
                now: time
            )
        }
        let heldCeilingAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 17_000_000,
            ceilingBps: 200_000_000,
            now: 20
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(secondAction == .none)
        #expect(thirdAction == .none)
        #expect(delayedRecoveryAction == .probe(targetBitrateBps: 17_000_000))
        #expect(heldCeilingAction == .none)
        #expect(controller.diagnostics.promotionCeilingBps == 17_000_000)
        #expect(controller.state == .stable)
    }

    @Test("Dynamic route recovery can reopen the learned ceiling after sustained clean telemetry")
    func dynamicRouteRecoveryReopensLearnedCeilingAfterSustainedCleanTelemetry() {
        var controller = MirageReceiverHealthController(promotionRecoveryMode: .dynamicRoute)
        let stressedSnapshot = severeTransportSnapshot()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)

        let firstAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 200_000_000,
            now: 0
        )
        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 2
        )
        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 4
        )
        let delayedRecoveryAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 200_000_000,
            now: 12
        )
        controller.noteProbeSucceeded(now: 12)
        for time in stride(from: 13.0, through: 19.0, by: 1.0) {
            _ = controller.advance(
                snapshots: [healthySnapshot],
                currentBitrateBps: 17_000_000,
                ceilingBps: 200_000_000,
                now: time
            )
        }
        let reopenedAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 17_000_000,
            ceilingBps: 200_000_000,
            now: 20
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(delayedRecoveryAction == .probe(targetBitrateBps: 17_000_000))
        #expect(reopenedAction == .probe(targetBitrateBps: 20_000_000))
        #expect(controller.diagnostics.promotionCeilingBps == 20_000_000)
    }

    @Test("Failed probe cooldown survives controller reset")
    func failedProbeCooldownSurvivesControllerReset() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.62)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let firstProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        controller.noteProbeFailed(now: 2)
        controller.reset()

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 7
        )
        let suppressedProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 7.5
        )
        let resumedProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 8
        )

        #expect(firstProbe == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.diagnostics.nextProbeAllowedAt == 8)
        #expect(suppressedProbe == .none)
        #expect(resumedProbe == .probe(targetBitrateBps: 32_000_000))
    }

    private func healthySnapshot(activeQuality: Double) -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            submittedFPS: 60,
            uniqueSubmittedFPS: 60,
            pendingFrameCount: 0,
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
        snapshot.submittedFPS = 0
        snapshot.uniqueSubmittedFPS = 0
        snapshot.decodeHealthy = false
        return snapshot
    }

    private func captureBoundButTransportHealthySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostCaptureIngressFPS = 44
        snapshot.hostCaptureFPS = 43
        snapshot.hostEncodeAttemptFPS = 43
        snapshot.hostEncodedFPS = 43
        snapshot.receivedFPS = 43
        snapshot.decodedFPS = 43
        snapshot.submittedFPS = 43
        snapshot.uniqueSubmittedFPS = 43
        return snapshot
    }

    private func encodeBoundButTransportHealthySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostCaptureIngressFPS = 60
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 42
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 21
        snapshot.receivedFPS = 42
        snapshot.decodedFPS = 42
        snapshot.submittedFPS = 42
        snapshot.uniqueSubmittedFPS = 42
        return snapshot
    }

    private func mixedBoundButTransportHealthySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = encodeBoundButTransportHealthySnapshot()
        snapshot.decodedFPS = 18
        snapshot.submittedFPS = 18
        snapshot.uniqueSubmittedFPS = 18
        snapshot.decodeHealthy = false
        return snapshot
    }

    private func delayOnlyBurstSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendStartDelayAverageMs = 3.5
        snapshot.hostSendCompletionAverageMs = 14
        return snapshot
    }

    private func packetPacerOnlySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostPacketPacerAverageSleepMs = 1.0
        return snapshot
    }

    private func presentationBoundButTransportHealthySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.submittedFPS = 43
        snapshot.uniqueSubmittedFPS = 43
        snapshot.clientOverwrittenPendingFrames = 2
        snapshot.clientDisplayLayerNotReadyCount = 1
        snapshot.clientPendingFrameAgeMs = 24
        return snapshot
    }
}
#endif
