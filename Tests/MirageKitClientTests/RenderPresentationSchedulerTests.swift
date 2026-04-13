//
//  RenderPresentationSchedulerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

#if os(macOS)
private final class PendingFrameState: @unchecked Sendable {
    var hasPendingAfterFirstSubmit = false
}

@MainActor
@Suite("Render Presentation Scheduler")
struct RenderPresentationSchedulerTests {
    @Test("Active live frame arrival coalesces into one scheduled pass per turn")
    func activeLiveFrameArrivalCoalescesIntoOneScheduledPassPerTurn() {
        let streamID: StreamID = 901
        var submitCount = 0
        var scheduledCallbacks: [@MainActor () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { 42 },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in
                submitCount += 1
                return false
            },
            hasPendingFrame: { _ in false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayLinkActive(true)

        scheduler.handleFrameAvailable(referenceTime: 1)
        scheduler.handleFrameAvailable(referenceTime: 2)
        scheduler.handleFrameAvailable(referenceTime: 3)

        #expect(submitCount == 0)
        #expect(scheduledCallbacks.count == 1)
        let callback = scheduledCallbacks.removeFirst()
        callback()
        #expect(submitCount == 1)
    }

    @Test("Active live scheduled pass queues exactly one follow-up when a newer frame is pending")
    func activeLiveScheduledPassQueuesOneFollowUpWhenNewerFrameIsPending() {
        let streamID: StreamID = 902
        var submitCount = 0
        var scheduledCallbacks: [@MainActor () -> Void] = []
        let pendingState = PendingFrameState()

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { 99 },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in
                submitCount += 1
                if submitCount == 1 {
                    pendingState.hasPendingAfterFirstSubmit = true
                } else {
                    pendingState.hasPendingAfterFirstSubmit = false
                }
                return true
            },
            hasPendingFrame: { _ in pendingState.hasPendingAfterFirstSubmit }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayLinkActive(true)

        scheduler.handleFrameAvailable(referenceTime: 1)

        #expect(scheduledCallbacks.count == 1)
        let firstCallback = scheduledCallbacks.removeFirst()
        firstCallback()
        #expect(scheduledCallbacks.count == 1)
        let secondCallback = scheduledCallbacks.removeFirst()
        secondCallback()
        #expect(submitCount == 2)
    }

    @Test("Passive snapshot frame arrival submits immediately")
    func passiveSnapshotFrameArrivalSubmitsImmediately() {
        let streamID: StreamID = 903
        var submitCount = 0

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return false
            },
            hasPendingFrame: { _ in false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.passiveSnapshot)
        scheduler.setDisplayLinkActive(true)

        scheduler.handleFrameAvailable(referenceTime: 1)

        #expect(submitCount == 1)
    }

    @Test("Display link remains a fallback path when no coalesced pass is queued")
    func displayLinkRemainsAFallbackPathWhenNoCoalescedPassIsQueued() {
        let streamID: StreamID = 904
        var submitCount = 0

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return false
            },
            hasPendingFrame: { _ in false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayLinkActive(true)

        scheduler.displayLinkTick(referenceTime: 1)

        #expect(submitCount == 1)
    }

    @Test("Reset clears queued coalesced passes before they execute")
    func resetClearsQueuedCoalescedPassesBeforeTheyExecute() {
        let streamID: StreamID = 905
        var submitCount = 0
        var scheduledCallbacks: [@MainActor () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in
                submitCount += 1
                return false
            },
            hasPendingFrame: { _ in false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayLinkActive(true)

        scheduler.handleFrameAvailable(referenceTime: 1)
        #expect(scheduledCallbacks.count == 1)

        scheduler.reset()
        let callback = scheduledCallbacks.removeFirst()
        callback()

        #expect(submitCount == 0)
    }
}
#endif
