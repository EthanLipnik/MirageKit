//
//  RenderPresentationSchedulerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKitClient
import CoreGraphics
import MirageKit
import Testing

#if os(macOS)
private final class PendingFrameState: @unchecked Sendable {
    var hasPendingAfterFirstSubmit = false
}

private final class ScheduledMainActorActions: @unchecked Sendable {
    var actions: [@MainActor () -> Void] = []
}

private final class SimulatedPendingFrames: @unchecked Sendable {
    var pendingCount = 0
    var submittedCount = 0

    var hasPendingFrame: Bool {
        pendingCount > 0
    }

    func enqueue() {
        pendingCount += 1
    }

    func submit() -> MirageRenderSubmissionResult {
        guard pendingCount > 0 else { return .noPendingFrame }
        pendingCount -= 1
        submittedCount += 1
        return .submitted
    }
}

@MainActor
@Suite("Render Presentation Scheduler")
struct RenderPresentationSchedulerTests {
    @Test("Active live frame arrival coalesces until display clock starts")
    func activeLiveFrameArrivalCoalescesUntilDisplayClockStarts() {
        let streamID: StreamID = 901
        var submitCount = 0
        var scheduledCallbacks: [@Sendable () -> Void] = []

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
        pendingState.hasPendingAfterFirstSubmit = true
        scheduler.handleDisplayTick(referenceTime: 4)

        #expect(submitCount == 2)
    }

    @Test("Active live display clock suppresses arrival fallback after a fresh tick")
    func activeLiveDisplayClockSuppressesArrivalFallbackAfterFreshTick() {
        let streamID: StreamID = 906
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@Sendable () -> Void] = []
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
            hasPendingFrame: { true }
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

    @Test("Active live frame arrival suppresses immediate fallback but recovers after a missed-tick interval")
    func activeLiveFrameArrivalSuppressesImmediateFallbackButRecoversAfterMissedTickInterval() {
        let streamID: StreamID = 909
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@Sendable () -> Void] = []
        var wallTime: CFTimeInterval = 30
        let pendingFrames = SimulatedPendingFrames()

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { referenceTime in
                submitReferences.append(referenceTime)
                return pendingFrames.submit()
            },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(60)
        scheduler.setDisplayClockActive(true)

        pendingFrames.enqueue()
        scheduler.handleDisplayTick(referenceTime: 1)
        #expect(submitReferences == [1])
        pendingFrames.enqueue()
        wallTime += 0.010
        scheduler.handleFrameAvailable(referenceTime: 2)

        #expect(scheduledCallbacks.isEmpty)
        #expect(submitReferences == [1])

        wallTime += 0.010
        scheduler.handleFrameAvailable(referenceTime: 2.5)

        #expect(scheduledCallbacks.isEmpty)
        #expect(submitReferences == [1])

        wallTime += 0.002
        scheduler.handleFrameAvailable(referenceTime: 3)

        #expect(scheduledCallbacks.count == 1)
        scheduledCallbacks.removeFirst()()
        #expect(submitReferences == [1, 3])
        #expect(pendingFrames.submittedCount == 2)

        pendingFrames.enqueue()
        scheduler.handleDisplayTick(referenceTime: 4)
        #expect(submitReferences == [1, 3, 4])
    }

    @Test("Active live frame arrival catches up after a no-frame display tick")
    func activeLiveFrameArrivalCatchesUpAfterNoFrameDisplayTick() {
        let streamID: StreamID = 915
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []
        var wallTime: CFTimeInterval = 1

        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)
        pendingFrames.enqueue()
        wallTime = 1.010
        scheduler.handleFrameAvailable(referenceTime: 1.001)

        #expect(scheduledCallbacks.count == 1)
        scheduledCallbacks.removeFirst()()
        #expect(pendingFrames.submittedCount == 1)
        #expect(pendingFrames.pendingCount == 0)

        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.displayTickNoFrameCount == 1)
        #expect(telemetry.frameArrivalFallbackCount == 1)
        #expect(telemetry.frameArrivalFallbackScheduledCount == 1)
        #expect(telemetry.frameArrivalFallbackSubmittedCount == 1)
        #expect(telemetry.frameArrivedAfterNoFrameTickCount == 1)
        #expect(telemetry.noFrameTickToFrameArrivalMaxMs >= 9)
    }

    @Test("Active live frame arrival drains backlog but preserves a lone pending frame")
    func activeLiveFrameArrivalDrainsBacklogButPreservesLonePendingFrame() {
        let streamID: StreamID = 916
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []
        var wallTime: CFTimeInterval = 1

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        pendingFrames.enqueue()
        scheduler.handleDisplayTick(referenceTime: 1)
        #expect(pendingFrames.submittedCount == 1)

        pendingFrames.enqueue()
        scheduler.handleFrameAvailable(referenceTime: 1.001)
        #expect(scheduledCallbacks.isEmpty)

        pendingFrames.enqueue()
        wallTime = 1.05
        scheduler.handleFrameAvailable(referenceTime: 1.002)
        #expect(scheduledCallbacks.count == 1)
        scheduledCallbacks.removeFirst()()

        #expect(pendingFrames.submittedCount == 2)
        #expect(pendingFrames.pendingCount == 1)
    }

    @Test("Active live frame arrival falls back before the first active display tick")
    func activeLiveFrameArrivalFallsBackBeforeFirstActiveDisplayTick() {
        let streamID: StreamID = 908
        var submitReferences: [CFTimeInterval] = []
        var scheduledCallbacks: [@Sendable () -> Void] = []
        let wallTime: CFTimeInterval = 20

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

        scheduler.handleFrameAvailable(referenceTime: 2)

        #expect(scheduledCallbacks.count == 1)
        let callback = scheduledCallbacks.removeFirst()
        callback()
        #expect(submitReferences == [2])
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

    @Test("Idle active-live display tick polls without enqueueing a frame")
    func idleActiveLiveDisplayTickPollsWithoutEnqueueingFrame() {
        let streamID: StreamID = 910
        var submitCount = 0
        MirageRenderStreamStore.shared.clear(for: streamID)
        defer { MirageRenderStreamStore.shared.clear(for: streamID) }

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return .noPendingFrame
            },
            hasPendingFrame: { false }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)

        #expect(submitCount == 1)
        let telemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        #expect(telemetry.displayTickFPS >= 1)
        #expect(telemetry.displayTickNoFrameCount == 1)
    }

    @Test("Pending active-live display tick submits")
    func pendingActiveLiveDisplayTickSubmits() {
        let streamID: StreamID = 911
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

        scheduler.handleDisplayTick(referenceTime: 4)

        #expect(submitReferences == [4])
    }

    @Test("60Hz tick-led cadence presents each decoded frame with phase jitter")
    func sixtyHertzTickLedCadencePresentsEachDecodedFrameWithPhaseJitter() {
        let streamID: StreamID = 913
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(60)
        scheduler.setDisplayClockActive(true)

        for index in 0 ..< 60 {
            pendingFrames.enqueue()
            scheduler.handleDisplayTick(referenceTime: CFTimeInterval(index + 1) / 60.0)
        }

        #expect(pendingFrames.submittedCount == 60)
        #expect(pendingFrames.pendingCount == 0)
        #expect(scheduledCallbacks.isEmpty)
    }

    @Test("60Hz tick-led cadence tracks a 56fps decoded stream")
    func sixtyHertzTickLedCadenceTracksFiftySixFPSDecodedStream() {
        let streamID: StreamID = 914
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(60)
        scheduler.setDisplayClockActive(true)

        for tick in 1 ... 60 {
            if tick <= 56 {
                pendingFrames.enqueue()
            }
            scheduler.handleDisplayTick(referenceTime: CFTimeInterval(tick) / 60.0)
        }

        #expect(pendingFrames.submittedCount == 56)
        #expect(pendingFrames.pendingCount == 0)
        #expect(scheduledCallbacks.isEmpty)
    }

    @Test("60Hz cadence with late 56fps arrivals does not under-submit")
    func sixtyHertzCadenceWithLateFiftySixFPSArrivalsDoesNotUnderSubmit() {
        let streamID: StreamID = 917
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []
        var wallTime: CFTimeInterval = 0
        var nextTick: CFTimeInterval = 0

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(60)
        scheduler.setDisplayClockActive(true)

        for frameIndex in 0 ..< 56 {
            let arrivalTime = 0.015 + (Double(frameIndex) / 56.0)
            while nextTick <= arrivalTime {
                wallTime = nextTick
                scheduler.handleDisplayTick(referenceTime: nextTick)
                nextTick += 1.0 / 60.0
            }

            wallTime = arrivalTime
            pendingFrames.enqueue()
            scheduler.handleFrameAvailable(referenceTime: arrivalTime)
            while !scheduledCallbacks.isEmpty {
                scheduledCallbacks.removeFirst()()
            }
        }
        while nextTick <= 1.05 {
            wallTime = nextTick
            scheduler.handleDisplayTick(referenceTime: nextTick)
            nextTick += 1.0 / 60.0
        }

        #expect(pendingFrames.submittedCount == 56)
        #expect(pendingFrames.pendingCount == 0)
    }

    @Test("60Hz cadence with late 60fps arrivals catches up after no-frame ticks")
    func sixtyHertzCadenceWithLateSixtyFPSArrivalsCatchesUpAfterNoFrameTicks() {
        let streamID: StreamID = 918
        let pendingFrames = SimulatedPendingFrames()
        var scheduledCallbacks: [@Sendable () -> Void] = []
        var wallTime: CFTimeInterval = 0

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in pendingFrames.submit() },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setTargetFPS(60)
        scheduler.setDisplayClockActive(true)

        for frameIndex in 0 ..< 60 {
            let tickTime = Double(frameIndex) / 60.0
            wallTime = tickTime
            scheduler.handleDisplayTick(referenceTime: tickTime)

            let arrivalTime = tickTime + 0.010
            wallTime = arrivalTime
            pendingFrames.enqueue()
            scheduler.handleFrameAvailable(referenceTime: arrivalTime)
            while !scheduledCallbacks.isEmpty {
                scheduledCallbacks.removeFirst()()
            }
        }

        #expect(pendingFrames.submittedCount == 60)
        #expect(pendingFrames.pendingCount == 0)
    }

    @Test("Display layer not-ready with no active display clock arms a readiness retry")
    func displayLayerNotReadyWithNoActiveDisplayClockArmsReadinessRetry() {
        let streamID: StreamID = 904
        var submitCount = 0
        var readinessRetryCount = 0
        var scheduledCallbacks: [@Sendable () -> Void] = []

        let scheduler = MirageRenderPresentationScheduler(
            enqueueCoalescedPass: { action in
                scheduledCallbacks.append(action)
            },
            submit: { _ in
                submitCount += 1
                return .displayLayerNotReady
            },
            hasPendingFrame: { true },
            onDisplayLayerNotReady: {
                readinessRetryCount += 1
            }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)

        scheduler.requestReadinessRetry(referenceTime: 1)
        #expect(scheduledCallbacks.count == 1)
        let callback = scheduledCallbacks.removeFirst()
        callback()

        #expect(submitCount == 1)
        #expect(readinessRetryCount == 1)
    }

    @Test("Display layer not-ready with active display clock arms readiness recovery")
    func displayLayerNotReadyWithActiveDisplayClockArmsReadinessRecovery() {
        let streamID: StreamID = 912
        var submitCount = 0
        var readinessRetryCount = 0

        let scheduler = MirageRenderPresentationScheduler(
            submit: { _ in
                submitCount += 1
                return .displayLayerNotReady
            },
            hasPendingFrame: { true },
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

    @Test("Renderer-ready recovery waits for display cadence unless ticks under-run")
    func rendererReadyRecoveryWaitsForDisplayCadenceUnlessTicksUnderrun() {
        let streamID: StreamID = 916
        let pendingFrames = SimulatedPendingFrames()
        var submitReferences: [CFTimeInterval] = []
        var wallTime: CFTimeInterval = 10

        let scheduler = MirageRenderPresentationScheduler(
            referenceTimeProvider: { wallTime },
            submit: { referenceTime in
                let result = pendingFrames.submit()
                if result == .submitted {
                    submitReferences.append(referenceTime)
                }
                return result
            },
            hasPendingFrame: { pendingFrames.hasPendingFrame },
            pendingFrameCount: { pendingFrames.pendingCount }
        )
        scheduler.setStreamID(streamID)
        scheduler.setPresentationTier(.activeLive)
        scheduler.setDisplayClockActive(true)

        scheduler.handleDisplayTick(referenceTime: 1)
        pendingFrames.enqueue()
        scheduler.requestRendererReadySubmission(referenceTime: 2)
        #expect(submitReferences.isEmpty)

        wallTime += 0.020
        scheduler.requestRendererReadySubmission(referenceTime: 2.5)
        #expect(submitReferences.isEmpty)

        wallTime += 0.002
        scheduler.requestRendererReadySubmission(referenceTime: 3)

        #expect(submitReferences == [3])
        #expect(pendingFrames.submittedCount == 1)
    }

    @Test("macOS display clock throttles physical ticks to target FPS")
    func macOSDisplayClockThrottlesPhysicalTicksToTargetFPS() {
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 0, now: 10, targetFPS: 120))
        #expect(!MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.003, targetFPS: 120))
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.008, targetFPS: 120))
        #expect(!MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.0084, targetFPS: 60))
        #expect(MirageMacDisplayClock.shouldEmitTick(lastEmittedTickTime: 10, now: 10.0150, targetFPS: 60))
    }

    @Test("macOS display clock restarts only when display ID changes")
    func macOSDisplayClockRestartDecisionUsesDisplayID() {
        #expect(!MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: nil, newDisplayID: nil))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: nil, newDisplayID: CGDirectDisplayID(1)))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: nil))
        #expect(!MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: CGDirectDisplayID(1)))
        #expect(MirageMacDisplayClock.shouldRestartDisplayLink(currentDisplayID: CGDirectDisplayID(1), newDisplayID: CGDirectDisplayID(2)))
    }

    @Test("macOS display tick relay coalesces callbacks into latest main delivery")
    func macOSDisplayTickRelayCoalescesCallbacksIntoLatestMainDelivery() {
        let scheduled = ScheduledMainActorActions()
        var deliveredReferences: [CFTimeInterval] = []
        let relay = MirageMacDisplayTickRelay(
            enqueueDelivery: { action in
                scheduled.actions.append(action)
            },
            deliver: { referenceTime in
                deliveredReferences.append(referenceTime)
            }
        )

        relay.receive(referenceTime: 1)
        relay.receive(referenceTime: 2)
        relay.receive(referenceTime: 3)

        #expect(scheduled.actions.count == 1)
        #expect(relay.coalescedCallbackCountSnapshot() == 2)
        scheduled.actions.removeFirst()()
        #expect(deliveredReferences == [3])

        relay.receive(referenceTime: 4)
        #expect(scheduled.actions.count == 1)
        relay.cancel()
        scheduled.actions.removeFirst()()

        #expect(deliveredReferences == [3])
    }

    @Test("Reset clears queued passive passes before they execute")
    func resetClearsQueuedPassivePassesBeforeTheyExecute() {
        let streamID: StreamID = 905
        var submitCount = 0
        var scheduledCallbacks: [@Sendable () -> Void] = []

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
