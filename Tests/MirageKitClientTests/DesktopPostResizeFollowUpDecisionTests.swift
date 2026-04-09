//
//  DesktopPostResizeFollowUpDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/8/26.
//
//  Desktop post-resize follow-up dispatch decisions.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Post-Resize Follow-Up Decision")
struct DesktopPostResizeFollowUpDecisionTests {
    @Test("Missing pending target stays idle")
    func missingPendingTargetStaysIdle() {
        let decision = desktopPostResizeFollowUpDecision(
            pendingTargetDisplaySize: .zero,
            awaitingPostResizeFirstFrame: false
        )

        #expect(decision == .noPendingResize)
    }

    @Test("Pending target waits for first presented frame when post-resize recovery is active")
    func pendingTargetWaitsForFirstPresentedFrame() {
        let decision = desktopPostResizeFollowUpDecision(
            pendingTargetDisplaySize: CGSize(width: 1920, height: 1204),
            awaitingPostResizeFirstFrame: true
        )

        #expect(decision == .awaitFirstPresentedFrame)
    }

    @Test("Pending target flushes immediately once post-resize recovery settles")
    func pendingTargetFlushesOnceRecoverySettles() {
        let decision = desktopPostResizeFollowUpDecision(
            pendingTargetDisplaySize: CGSize(width: 1920, height: 1204),
            awaitingPostResizeFirstFrame: false
        )

        #expect(decision == .flushPendingResize)
    }
}
#endif
