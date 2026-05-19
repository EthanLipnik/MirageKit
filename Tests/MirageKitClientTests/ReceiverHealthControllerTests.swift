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
    @Test("Severe transport pressure backs off after consecutive samples")
    func severeTransportPressureBacksOffAfterConsecutiveSamples() {
        var controller = MirageReceiverHealthController()
        let snapshot = severeTransportSnapshot()

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 10
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 12
        )

        #expect(firstAction == .none)
        #expect(secondAction == .backoff(targetBitrateBps: 17_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Delay-only sender pressure suppresses probes without backoff")
    func delayOnlySenderPressureSuppressesProbesWithoutBackoff() {
        var controller = MirageReceiverHealthController()
        let delayedSnapshot = delayOnlySnapshot()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)

        for time in [0.0, 2.0, 4.0] {
            let action = controller.advance(
                snapshots: [delayedSnapshot],
                currentBitrateBps: 20_000_000,
                ceilingBps: 300_000_000,
                now: time
            )
            #expect(action == .none)
        }
        let firstCleanAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 6
        )
        let suppressedProbeAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 6.5
        )
        let resumedProbeAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 7.1
        )

        #expect(firstCleanAction == .none)
        #expect(suppressedProbeAction == .none)
        #expect(resumedProbeAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Startup queue spikes suppress backoff without transport loss")
    func startupQueueSpikesSuppressBackoffWithoutTransportLoss() {
        var controller = MirageReceiverHealthController()
        let snapshot = startupQueueSpikeSnapshot()

        for time in [0.0, 2.0, 4.0] {
            let action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 20_000_000,
                ceilingBps: 300_000_000,
                now: time
            )
            #expect(action == .none)
        }

        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason != nil)
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

    @Test("Recent interaction defers probes while allowing severe backoff")
    func recentInteractionDefersProbesWhileAllowingSevereBackoff() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let stressedSnapshot = severeTransportSnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 0,
            allowsNewProbe: false
        )
        let deferredProbe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 2,
            allowsNewProbe: false
        )
        let firstStressAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 4,
            allowsNewProbe: false
        )
        let secondStressAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 6,
            allowsNewProbe: false
        )

        #expect(deferredProbe == .none)
        #expect(firstStressAction == .none)
        #expect(secondStressAction == .backoff(targetBitrateBps: 17_000_000))
    }

    @Test("Pending probe rolls back only on transport pressure")
    func pendingProbeRollsBackOnlyOnTransportPressure() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let stressedSnapshot = severeTransportSnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let rollback = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(probe == .probe(targetBitrateBps: 32_000_000))
        #expect(rollback == .backoff(targetBitrateBps: 20_000_000))
    }

    @Test("Pending probe ignores decode stalls without unsafe ceiling")
    func pendingProbeIgnoresDecodeStallsWithoutUnsafeCeiling() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let decodeStalledSnapshot = decodeStalledButTransportHealthySnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let decodeAction = controller.advance(
            snapshots: [decodeStalledSnapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(probe == .probe(targetBitrateBps: 32_000_000))
        #expect(decodeAction == .none)
        #expect(controller.state == .stable)
    }

    @Test("Presentation-bound samples do not block transport probing")
    func presentationBoundSamplesDoNotBlockTransportProbing() {
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

    @Test("Host cadence limits do not block clean transport probing")
    func hostCadenceLimitsDoNotBlockCleanTransportProbing() {
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

        #expect(action == .probe(targetBitrateBps: 60_000_000))
    }

    @Test("Transport drops trigger backoff even when decode metrics look healthy")
    func transportDropsTriggerBackoffEvenWhenDecodeLooksHealthy() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostStalePacketDrops = 12

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 12
        )
        let thirdAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 14
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(thirdAction == .backoff(targetBitrateBps: 18_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Client fragment loss triggers backoff without host send pressure")
    func clientFragmentLossTriggersBackoffWithoutHostSendPressure() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerIncompleteFrameTimeouts = 3
        snapshot.clientReassemblerMissingFragmentTimeouts = 160

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 2
        )

        #expect(firstAction == .none)
        #expect(secondAction == .backoff(targetBitrateBps: 40_800_000))
        #expect(controller.lastTransportPressureReason == "client fragment loss frames=3 missing=160")
    }

    @Test("Delivery collapse without transport evidence does not back off")
    func deliveryCollapseWithoutTransportEvidenceDoesNotBackOff() {
        var controller = MirageReceiverHealthController()
        var networkSnapshot = healthySnapshot(activeQuality: 0.62)
        networkSnapshot.hostEncodedFPS = 60
        networkSnapshot.receivedFPS = 8
        networkSnapshot.decodedFPS = 8
        networkSnapshot.submittedFPS = 8
        networkSnapshot.uniqueSubmittedFPS = 8

        _ = controller.advance(
            snapshots: [networkSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )
        let networkBackoff = controller.advance(
            snapshots: [networkSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 12
        )

        var decodeSnapshot = networkSnapshot
        decodeSnapshot.decodeHealthy = false
        var decodeController = MirageReceiverHealthController()
        _ = decodeController.advance(
            snapshots: [decodeSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )
        let decodeAction = decodeController.advance(
            snapshots: [decodeSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 12
        )

        #expect(networkBackoff == .probe(targetBitrateBps: 60_000_000))
        #expect(decodeAction == .probe(targetBitrateBps: 60_000_000))
    }

    @Test("Missing host metrics hold")
    func missingHostMetricsHold() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hasHostMetrics = false

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    func healthySnapshot(activeQuality: Double) -> MirageClientMetricsSnapshot {
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
        snapshot.hostSenderLocalDeadlineDrops = 0
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
        snapshot.hostSendQueueBytes = 2_500_000
        snapshot.hostSendStartDelayAverageMs = 9
        snapshot.hostSendCompletionAverageMs = 35
        snapshot.hostPacketPacerAverageSleepMs = 2.5
        snapshot.hostStalePacketDrops = 24
        return snapshot
    }

    private func delayOnlySnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendStartDelayAverageMs = 4.5
        snapshot.hostSendCompletionAverageMs = 20
        return snapshot
    }

    private func startupQueueSpikeSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendQueueBytes = 2_500_000
        snapshot.hostSendStartDelayAverageMs = 9
        snapshot.hostSendCompletionAverageMs = 35
        snapshot.hostPacketPacerAverageSleepMs = 2.5
        snapshot.hostStalePacketDrops = 0
        snapshot.hostSenderLocalDeadlineDrops = 0
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

    func remoteKeyframeStarvedSnapshot() -> MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.receivedFPS = 0
        snapshot.decodedFPS = 0
        snapshot.submittedFPS = 0
        snapshot.uniqueSubmittedFPS = 0
        snapshot.decodeHealthy = false
        snapshot.clientReassemblerPendingKeyframeCount = 2
        snapshot.clientDroppedFrames = 1
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
