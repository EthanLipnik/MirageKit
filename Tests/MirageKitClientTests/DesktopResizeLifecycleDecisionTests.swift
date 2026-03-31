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
    @Test("Inactive and background metrics are ignored")
    func inactiveAndBackgroundMetricsAreIgnored() {
        let resigned = desktopResizeLifecycleDecision(
            state: .active,
            event: .didResignActive
        )
        #expect(resigned.nextState == .suspended)
        #expect(resigned.shouldProcessDrawableMetrics == false)

        let ignoredWhileSuspended = desktopResizeLifecycleDecision(
            state: resigned.nextState,
            event: .drawableMetricsChanged
        )
        #expect(ignoredWhileSuspended.nextState == .suspended)
        #expect(ignoredWhileSuspended.shouldProcessDrawableMetrics == false)

        let backgrounded = desktopResizeLifecycleDecision(
            state: .awaitingFreshActiveMetrics,
            event: .didEnterBackground
        )
        #expect(backgrounded.nextState == .suspended)
        #expect(backgrounded.shouldProcessDrawableMetrics == false)
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
