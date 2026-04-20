//
//  DesktopResizeLifecycleDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Desktop Resize Lifecycle Decision")
struct DesktopResizeLifecycleDecisionTests {
    @Test("Only backgrounding suspends drawable-metric processing")
    func onlyBackgroundingSuspendsDrawableMetricProcessing() {
        let activeMetrics = desktopResizeLifecycleDecision(
            state: .active,
            event: .drawableMetricsChanged
        )
        #expect(activeMetrics.nextState == .active)
        #expect(activeMetrics.shouldProcessDrawableMetrics)

        let backgrounded = desktopResizeLifecycleDecision(
            state: .active,
            event: .didEnterBackground
        )
        #expect(backgrounded.nextState == .suspended)
        #expect(backgrounded.shouldProcessDrawableMetrics == false)

        let ignoredWhileSuspended = desktopResizeLifecycleDecision(
            state: backgrounded.nextState,
            event: .drawableMetricsChanged
        )
        #expect(ignoredWhileSuspended.nextState == .suspended)
        #expect(ignoredWhileSuspended.shouldProcessDrawableMetrics == false)

        let inactive = desktopResizeLifecycleDecision(
            state: .active,
            event: .willResignActive
        )
        #expect(inactive.nextState == .suspended)
        #expect(inactive.shouldProcessDrawableMetrics == false)
    }

    @Test("Foreground holdoff requires a fresh active metrics sample before dispatch resumes")
    func foregroundHoldoffRequiresFreshMetrics() {
        let heldOff = desktopResizeLifecycleDecision(
            state: .suspended,
            event: .foregroundHoldoffElapsed
        )
        #expect(heldOff.nextState == .awaitingFreshActiveMetrics)
        #expect(heldOff.shouldProcessDrawableMetrics == false)

        let firstFreshMetrics = desktopResizeLifecycleDecision(
            state: heldOff.nextState,
            event: .drawableMetricsChanged
        )
        #expect(firstFreshMetrics.nextState == .active)
        #expect(firstFreshMetrics.shouldProcessDrawableMetrics)

        let subsequentMetrics = desktopResizeLifecycleDecision(
            state: firstFreshMetrics.nextState,
            event: .drawableMetricsChanged
        )
        #expect(subsequentMetrics.nextState == .active)
        #expect(subsequentMetrics.shouldProcessDrawableMetrics)
    }
}
#endif
