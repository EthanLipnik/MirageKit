//
//  ReceiverHealthControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Coverage for the automatic receiver-health state machine.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Receiver Health Controller")
struct ReceiverHealthControllerTests {
    @Test("Severe decode stalls back off immediately")
    func severeDecodeStallsBackOffImmediately() {
        var controller = MirageReceiverHealthController()
        let snapshot = stalledSnapshot()

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 10
        )

        #expect(action == .backoff(targetBitrateBps: 15_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Healthy samples probe upward after three clean windows")
    func healthySamplesProbeUpwardAfterThreeCleanWindows() {
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
        let thirdAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(thirdAction == .probe(targetBitrateBps: 60_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Healthy samples settle backoff without restoring bitrate")
    func healthySamplesSettleBackoffWithoutRestoringBitrate() {
        var controller = MirageReceiverHealthController()
        let stalledSnapshot = stalledSnapshot()
        let healthySnapshot = healthySnapshot(activeQuality: 0.66)

        let firstAction = controller.advance(
            snapshots: [stalledSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 0
        )
        let firstHealthyAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 1
        )
        let secondHealthyAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 2
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(firstHealthyAction == .none)
        #expect(secondHealthyAction == .none)
        #expect(controller.state == .stable)
    }

    @Test("Successful probes apply an eight-second cooldown")
    func successfulProbesApplyCooldown() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.60)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let initialProbe = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )
        #expect(initialProbe == .probe(targetBitrateBps: 60_000_000))

        controller.noteProbeSucceeded(now: 4)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 60_000_000,
            ceilingBps: 300_000_000,
            now: 6
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 60_000_000,
            ceilingBps: 300_000_000,
            now: 8
        )
        let cooldownAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 60_000_000,
            ceilingBps: 300_000_000,
            now: 10
        )
        let postCooldownAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 60_000_000,
            ceilingBps: 300_000_000,
            now: 12
        )

        #expect(cooldownAction == .none)
        #expect(postCooldownAction == .probe(targetBitrateBps: 100_000_000))
    }

    @Test("Failed probes apply a twelve-second cooldown")
    func failedProbesApplyCooldown() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.58)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        controller.noteProbeFailed(now: 4)

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 6
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 8
        )
        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 10
        )
        let stillCoolingDown = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 14
        )
        let cooledDown = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 16
        )

        #expect(stillCoolingDown == .none)
        #expect(cooledDown == .probe(targetBitrateBps: 60_000_000))
    }

    @Test("Healthy saturated streams stop probing upward")
    func healthySaturatedStreamsStopProbingUpward() {
        var controller = MirageReceiverHealthController()
        let saturatedSnapshot = healthySnapshot(activeQuality: 0.82)

        let firstAction = controller.advance(
            snapshots: [saturatedSnapshot],
            currentBitrateBps: 120_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [saturatedSnapshot],
            currentBitrateBps: 120_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let thirdAction = controller.advance(
            snapshots: [saturatedSnapshot],
            currentBitrateBps: 120_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(thirdAction == .none)
    }

    @Test("Sustained severe stress keeps stepping bitrate downward")
    func sustainedSevereStressKeepsSteppingBitrateDownward() {
        var controller = MirageReceiverHealthController()
        let stalledSnapshot = stalledSnapshot()

        let firstAction = controller.advance(
            snapshots: [stalledSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 0
        )
        let cooldownAction = controller.advance(
            snapshots: [stalledSnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 1
        )
        let secondAction = controller.advance(
            snapshots: [stalledSnapshot],
            currentBitrateBps: 15_000_000,
            ceilingBps: 50_000_000,
            now: 3
        )

        #expect(firstAction == .backoff(targetBitrateBps: 15_000_000))
        #expect(cooldownAction == .none)
        #expect(secondAction == .backoff(targetBitrateBps: 11_250_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Worst active stream drives the automatic decision")
    func worstActiveStreamDrivesTheAutomaticDecision() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.60)
        let stalledSnapshot = stalledSnapshot()

        let action = controller.advance(
            snapshots: [healthySnapshot, stalledSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 10
        )

        #expect(action == .backoff(targetBitrateBps: 15_000_000))
        #expect(controller.state == .backingOff)
    }

    private func healthySnapshot(activeQuality: Double) -> MirageClientMetricsSnapshot {
        MirageClientMetricsSnapshot(
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
    }

    private func stalledSnapshot() -> MirageClientMetricsSnapshot {
        MirageClientMetricsSnapshot(
            decodedFPS: 0,
            receivedFPS: 0,
            presentedFPS: 0,
            uniquePresentedFPS: 0,
            renderBufferDepth: 0,
            decodeHealthy: false,
            hostTargetFrameRate: 60,
            hasHostMetrics: true
        )
    }
}
#endif
