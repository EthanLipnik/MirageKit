//
//  MirageMacDisplayClockPresentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import Foundation
@testable import MirageKitClientPresentation
import Testing

@Suite("Mirage Mac Display Clock")
struct MirageMacDisplayClockPresentationTests {
    @Test("Mac display clock throttles physical ticks to target FPS")
    func macDisplayClockThrottlesPhysicalTicksToTargetFPS() {
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 0, now: 10, targetFPS: 120))
        #expect(!MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.003, targetFPS: 120))
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.008, targetFPS: 120))
        #expect(!MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.0084, targetFPS: 60))
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.0150, targetFPS: 60))
    }

    @Test("Mac display clock restart decision uses display IDs")
    func macDisplayClockRestartDecisionUsesDisplayIDs() {
        #expect(!MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: nil, newDisplayID: nil))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: nil, newDisplayID: CGDirectDisplayID(1)))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: nil))
        #expect(!MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: CGDirectDisplayID(1)))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: CGDirectDisplayID(2)))
    }

    @MainActor
    @Test("Mac display tick relay coalesces callbacks into latest main delivery")
    func macDisplayTickRelayCoalescesCallbacksIntoLatestMainDelivery() {
        let scheduledActions = ScheduledDisplayClockActions()
        var deliveredTimes: [CFTimeInterval] = []
        let relay = MirageMacDisplayTickRelay(
            enqueueDelivery: { action in
                scheduledActions.actions.append(action)
            },
            deliver: { referenceTime in
                deliveredTimes.append(referenceTime)
            }
        )

        relay.receive(referenceTime: 1)
        relay.receive(referenceTime: 2)
        relay.receive(referenceTime: 3)

        #expect(scheduledActions.actions.count == 1)
        #expect(relay.coalescedCallbackCountSnapshot() == 2)
        scheduledActions.actions.removeFirst()()
        #expect(deliveredTimes == [3])

        relay.receive(referenceTime: 4)
        relay.cancel()
        scheduledActions.actions.removeFirst()()
        #expect(deliveredTimes == [3])
    }
}

private final class ScheduledDisplayClockActions: @unchecked Sendable {
    var actions: [@MainActor () -> Void] = []
}
#endif
