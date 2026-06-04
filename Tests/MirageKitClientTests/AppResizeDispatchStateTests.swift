//
//  AppResizeDispatchStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

@testable import MirageKitClient
import CoreGraphics
import MirageKit
import Testing

@Suite("App Resize Dispatch State")
struct AppResizeDispatchStateTests {
    @Test("Pending target waits until current resize completes")
    func pendingTargetWaitsUntilCurrentCompletes() {
        var state = AppWindowResizeDispatchState()

        state.enqueue(CGSize(width: 900, height: 700))
        let firstTarget = state.beginNextDispatch(now: 0)
        #expect(firstTarget == CGSize(width: 900, height: 700))

        state.enqueue(CGSize(width: 1000, height: 800))

        #expect(state.hasInFlightResize)
        #expect(state.hasPendingResize)
        #expect(state.dispatchDelay(now: 0.05) == nil)

        let staleResult = resizeResult(
            requestedWidth: 880,
            requestedHeight: 680,
            outcome: .failed
        )
        let staleCompleted = state.complete(result: staleResult, now: 0.06)
        #expect(!staleCompleted)
        #expect(state.hasInFlightResize)

        let currentResult = resizeResult(
            requestedWidth: 900,
            requestedHeight: 700,
            outcome: .noChange
        )
        let currentCompleted = state.complete(result: currentResult, now: 0.07)
        #expect(currentCompleted)
        #expect(!state.hasInFlightResize)
        #expect(state.hasPendingResize)
        #expect((state.dispatchDelay(now: 0.07) ?? 1) > 0)

        #expect(state.beginNextDispatch(now: 0.10) == CGSize(width: 1000, height: 800))
    }

    @Test("Returning to in-flight target clears pending intermediate resize")
    func returningToInFlightTargetClearsPendingIntermediateResize() {
        var state = AppWindowResizeDispatchState()

        state.enqueue(CGSize(width: 900, height: 700))
        let firstTarget = state.beginNextDispatch(now: 0)
        #expect(firstTarget == CGSize(width: 900, height: 700))
        state.enqueue(CGSize(width: 1000, height: 800))
        #expect(state.hasPendingResize)

        state.enqueue(CGSize(width: 900, height: 700))

        #expect(state.hasInFlightResize)
        #expect(!state.hasPendingResize)
        #expect(state.coalescedCount == 2)
    }

    @Test("Repeated failures back off but later settled targets still send")
    func repeatedFailuresBackOffButLaterTargetsStillSend() {
        var state = AppWindowResizeDispatchState()

        state.enqueue(CGSize(width: 900, height: 700))
        let firstTarget = state.beginNextDispatch(now: 0)
        #expect(firstTarget == CGSize(width: 900, height: 700))
        let firstCompleted = state.complete(
            result: resizeResult(
                requestedWidth: 900,
                requestedHeight: 700,
                outcome: .failed,
                reason: "didNotConverge"
            ),
            now: 0.02
        )
        #expect(firstCompleted)

        state.enqueue(CGSize(width: 1000, height: 800))
        let secondTarget = state.beginNextDispatch(now: 0.10)
        #expect(secondTarget == CGSize(width: 1000, height: 800))
        let secondCompleted = state.complete(
            result: resizeResult(
                requestedWidth: 1000,
                requestedHeight: 800,
                outcome: .failed,
                reason: "didNotConverge"
            ),
            now: 0.12
        )
        #expect(secondCompleted)

        state.enqueue(CGSize(width: 1100, height: 820))
        let backoffDelay = state.dispatchDelay(now: 0.12)

        #expect((backoffDelay ?? 0) >= 0.34)
        let thirdTarget = state.beginNextDispatch(now: 0.47)
        #expect(thirdTarget == CGSize(width: 1100, height: 820))
    }

    private func resizeResult(
        requestedWidth: Int,
        requestedHeight: Int,
        outcome: MirageAppWindowResizeResultOutcome,
        reason: String? = nil
    ) -> AppWindowResizeResultMessage {
        AppWindowResizeResultMessage(
            streamID: 101,
            mediaStreamID: 100,
            windowID: 10101,
            outcome: outcome,
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            observedWidth: requestedWidth,
            observedHeight: requestedHeight,
            minWidth: nil,
            minHeight: nil,
            reason: reason
        )
    }
}
