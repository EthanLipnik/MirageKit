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
    @Test("Only backgrounding suspends resize-metric processing")
    func onlyBackgroundingSuspendsResizeMetricProcessing() {
        let activeContainer = desktopResizeLifecycleDecision(
            state: .active,
            event: .containerSizeChanged
        )
        #expect(activeContainer.nextState == .active)
        #expect(activeContainer.shouldProcessDrawableMetrics)

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

        let ignoredContainerWhileSuspended = desktopResizeLifecycleDecision(
            state: backgrounded.nextState,
            event: .containerSizeChanged
        )
        #expect(ignoredContainerWhileSuspended.nextState == .suspended)
        #expect(ignoredContainerWhileSuspended.shouldProcessDrawableMetrics == false)

        let ignoredDrawableWhileSuspended = desktopResizeLifecycleDecision(
            state: backgrounded.nextState,
            event: .drawableMetricsChanged
        )
        #expect(ignoredDrawableWhileSuspended.nextState == .suspended)
        #expect(ignoredDrawableWhileSuspended.shouldProcessDrawableMetrics == false)

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
        #expect(heldOff.nextState == .active)
        #expect(heldOff.shouldProcessDrawableMetrics == false)

        let firstPostDebounceContainerMetrics = desktopResizeLifecycleDecision(
            state: heldOff.nextState,
            event: .containerSizeChanged
        )
        #expect(firstPostDebounceContainerMetrics.nextState == .active)
        #expect(firstPostDebounceContainerMetrics.shouldProcessDrawableMetrics)

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
