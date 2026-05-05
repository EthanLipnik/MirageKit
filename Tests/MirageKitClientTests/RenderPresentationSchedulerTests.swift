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
    @Test("Active live frame arrival waits for display clock")
    func activeLiveFrameArrivalWaitsForDisplayClock() {
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
        #expect(scheduledCallbacks.isEmpty)

        scheduler.setDisplayClockActive(true)
        scheduler.handleDisplayTick(referenceTime: 4)
        #expect(submitCount == 1)
    }

    @Test("Active live display ticks are the only active submission path")
    func activeLiveDisplayTicksAreOnlyActiveSubmissionPath() {
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

        #expect(submitCount == 0)

        scheduler.setDisplayClockActive(true)
        scheduler.handleDisplayTick(referenceTime: 4)

        #expect(submitCount == 1)
    }

    @Test("Active live display clock waits for ticks instead of arrival passes")
    func activeLiveDisplayClockWaitsForTicksInsteadOfArrivalPasses() {
        let streamID: StreamID = 906
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@MainActor () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
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
        scheduler.setDisplayClockActive(true)

        scheduler.handleFrameAvailable(referenceTime: 1)
        scheduler.handleFrameAvailable(referenceTime: 2)

        #expect(scheduledCallbacks.isEmpty)
        #expect(submitReferences.isEmpty)

        scheduler.handleDisplayTick(referenceTime: 3)

        #expect(submitReferences == [3])
    }

    @Test("Immediate submission waits for display tick while display clock is active")
    func immediateSubmissionWaitsForDisplayTickWhileDisplayClockIsActive() {
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
        #expect(submitReferences.isEmpty)

        scheduler.handleDisplayTick(referenceTime: 2)
        #expect(submitReferences == [2])
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
