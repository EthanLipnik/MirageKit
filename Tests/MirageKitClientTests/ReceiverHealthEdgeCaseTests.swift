//
//  ReceiverHealthEdgeCaseTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

#if os(macOS)
extension ReceiverHealthControllerTests {
    @Test("Clean variable ProMotion cadence above floor does not back off")
    func cleanVariableProMotionCadenceAboveFloorDoesNotBackOff() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostTargetFrameRate = 120
        snapshot.hostFrameBudgetMs = 8.33
        snapshot.hostCaptureIngressFPS = 120
        snapshot.hostCaptureFPS = 120
        snapshot.hostEncodeAttemptFPS = 120
        snapshot.hostEncodedFPS = 120
        snapshot.receivedFPS = 80
        snapshot.decodedFPS = 80
        snapshot.submittedFPS = 80
        snapshot.uniqueSubmittedFPS = 80

        var action: MirageReceiverHealthController.Action = .none
        for time in [10.0, 12.0, 14.0] {
            action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 80_000_000,
                ceilingBps: 80_000_000,
                now: time,
                minimumHealthyFrameRate: 60
            )
        }

        #expect(action == .none)
        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason == nil)
    }

    @Test("Remote keyframe starvation without transport evidence does not back off")
    func remoteKeyframeStarvationWithoutTransportEvidenceDoesNotBackOff() {
        var controller = MirageReceiverHealthController()
        let snapshot = remoteKeyframeStarvedSnapshot()

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 12
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason == nil)
    }

    @Test("Remote keyframe starvation still suppresses unsafe promotion")
    func remoteKeyframeStarvationStillSuppressesUnsafePromotion() {
        var controller = MirageReceiverHealthController()
        let snapshot = remoteKeyframeStarvedSnapshot()

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 2
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(controller.state == .stable)
    }
}
#endif
