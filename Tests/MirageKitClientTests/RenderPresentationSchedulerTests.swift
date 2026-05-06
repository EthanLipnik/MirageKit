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
    @Test("Active live frame arrival coalesces until display clock starts")
    func activeLiveFrameArrivalCoalescesUntilDisplayClockStarts() {
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
                return .noPendingFrame
            },
            hasPendingFrame: { false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)

        scheduler.handleFrameAvailable(referenceTime: 1)
        scheduler.handleFrameAvailable(referenceTime: 2)
        scheduler.handleFrameAvailable(referenceTime: 3)

        #expect(submitCount == 0)
        #expect(scheduledCallbacks.count == 1)

        scheduler.setDisplayClockActive(true)
        let callback = scheduledCallbacks.removeFirst()
        callback()
        #expect(submitCount == 0)

        scheduler.handleDisplayTick(referenceTime: 4)
        #expect(submitCount == 1)
    }

    @Test("Immediate active live submission can seed presentation before display clock starts")
    func immediateActiveLiveSubmissionCanSeedPresentationBeforeDisplayClockStarts() {
        let streamID: StreamID = 902
        var submitCount = 0
        let pendingState = PendingFrameState()

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { 99 },
            submit: { _ in
                submitCount += 1
                pendingState.hasPendingAfterFirstSubmit = false
                return .submitted
            },
            hasPendingFrame: { pendingState.hasPendingAfterFirstSubmit }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        pendingState.hasPendingAfterFirstSubmit = true

        scheduler.handleFrameAvailable(referenceTime: 1)
        scheduler.requestImmediateSubmission(referenceTime: 2)
        scheduler.requestReadinessRetry(referenceTime: 3)

        #expect(submitCount == 1)

        scheduler.setDisplayClockActive(true)
        scheduler.handleDisplayTick(referenceTime: 4)

        #expect(submitCount == 2)
    }

    @Test("Active live display clock suppresses arrival fallback after a fresh tick")
    func activeLiveDisplayClockSuppressesArrivalFallbackAfterFreshTick() {
        let streamID: StreamID = 906
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@MainActor () -> Void] = []
        var wallTime: CFTimeInterval = 10

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { referenceTime in
                submitReferences.append(referenceTime)
                return .submitted
            },
            hasPendingFrame: { false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(120)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)
        wallTime += 0.004
        scheduler.handleFrameAvailable(referenceTime: 1)
        scheduler.handleFrameAvailable(referenceTime: 2)

        #expect(scheduledCallbacks.isEmpty)
        #expect(submitReferences == [1])

        scheduler.handleDisplayTick(referenceTime: 3)

        #expect(submitReferences == [1, 3])
    }

    @Test("Active live frame arrival falls back when display ticks underfire")
    func activeLiveFrameArrivalFallsBackWhenDisplayTicksUnderfire() {
        let streamID: StreamID = 908
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@MainActor () -> Void] = []
        var wallTime: CFTimeInterval = 20

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { referenceTime in
                submitReferences.append(referenceTime)
                return .submitted
            },
            hasPendingFrame: { true }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(120)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)
        wallTime += 0.020
        scheduler.handleFrameAvailable(referenceTime: 2)

        #expect(scheduledCallbacks.count == 1)
        let callback = scheduledCallbacks.removeFirst()
        callback()
        #expect(submitReferences == [1, 2])
    }

    @Test("Immediate submission seeds presentation before first display tick")
    func immediateSubmissionSeedsPresentationBeforeFirstDisplayTick() {
        let streamID: StreamID = 907
        var submitReferences: [CFTimeInterval] = []

        let scheduler = MirageRenderPresentationScheduler(
            submit: { referenceTime in
                submitReferences.append(referenceTime)
                return .submitted
            },
            hasPendingFrame: { true }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        scheduler.requestImmediateSubmission(referenceTime: 1)
        #expect(submitReferences == [1])

        scheduler.handleDisplayTick(referenceTime: 2)
        #expect(submitReferences == [1, 2])
    }

    @Test("Passive snapshot frame arrival submits immediately")
    func passiveSnapshotFrameArrivalSubmitsImmediately() {
        let streamID: StreamID = 903
        var submitCount = 0

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return .noPendingFrame
            },
            hasPendingFrame: { false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.passiveSnapshot)

        scheduler.handleFrameAvailable(referenceTime: 1)

        #expect(submitCount == 1)
    }

    @Test("Display layer not-ready arms a readiness retry")
    func displayLayerNotReadyArmsReadinessRetry() {
        let streamID: StreamID = 904
        var submitCount = 0
        var readinessRetryCount = 0

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return .displayLayerNotReady
            },
            hasPendingFrame: { false },
            onDisplayLayerNotReady: {
                readinessRetryCount += 1
            }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)

        #expect(submitCount == 1)
        #expect(readinessRetryCount == 1)
    }

    @Test("macOS display clock throttles physical ticks to target FPS")
    func macOSDisplayClockThrottlesPhysicalTicksToTargetFPS() {
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 0, now: 10, targetFPS: 120))
        #expect(!MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.003, targetFPS: 120))
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.008, targetFPS: 120))
    }

    @Test("Reset clears queued passive passes before they execute")
    func resetClearsQueuedPassivePassesBeforeTheyExecute() {
        let streamID: StreamID = 905
        var submitCount = 0
        var scheduledCallbacks: [@MainActor () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in
                submitCount += 1
                return .noPendingFrame
            },
            hasPendingFrame: { false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.passiveSnapshot)

        scheduler.requestReadinessRetry(referenceTime: 1)
        #expect(scheduledCallbacks.count == 1)

        scheduler.reset()
        let callback = scheduledCallbacks.removeFirst()
        callback()

        #expect(submitCount == 0)
    }
}
#endif
