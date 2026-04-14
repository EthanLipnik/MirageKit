//
//  DesktopResizeCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing

#if os(macOS)
@MainActor
@Suite("Desktop Resize Coordinator")
struct DesktopResizeCoordinatorTests {
    private func target(
        logicalWidth: CGFloat = 1366,
        logicalHeight: CGFloat = 1024
    )
    -> DesktopResizeCoordinator.RequestGeometry {
        DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: logicalWidth, height: logicalHeight),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2048,
            encoderMaxHeight: 1536
        )
    }

    @Test("Accepts only the matching active transition")
    func acceptsOnlyMatchingActiveTransition() {
        let coordinator = DesktopResizeCoordinator()
        let transitionID = UUID()
        coordinator.beginTransition(
            streamID: 11,
            transitionID: transitionID,
            target: target()
        )

        #expect(coordinator.acceptTransition(streamID: 11, transitionID: transitionID))
        #expect(!coordinator.acceptTransition(streamID: 12, transitionID: transitionID))
        #expect(!coordinator.acceptTransition(streamID: 11, transitionID: UUID()))
        #expect(!coordinator.acceptTransition(streamID: 11, transitionID: nil))
    }

    @Test("Finish transition preserves queued latest target")
    func finishTransitionPreservesQueuedLatestTarget() {
        let coordinator = DesktopResizeCoordinator()
        let activeTarget = target()
        let queuedTarget = target(logicalWidth: 1512, logicalHeight: 982)
        coordinator.beginTransition(
            streamID: 19,
            transitionID: UUID(),
            target: activeTarget
        )
        coordinator.queueLatestTarget(queuedTarget)

        coordinator.finishTransition(outcome: .resized)

        #expect(coordinator.activeTransition == nil)
        #expect(coordinator.queuedTarget == queuedTarget)
        #expect(coordinator.latestRequestedTarget == queuedTarget)
        #expect(coordinator.isResizing)
        #expect(coordinator.maskActive)
    }

    @Test("Clear-all-state drops transition and queued targets")
    func clearAllStateDropsTransitionAndQueuedTargets() {
        let coordinator = DesktopResizeCoordinator()
        let activeTarget = target()
        let queuedTarget = target(logicalWidth: 1600, logicalHeight: 1000)
        coordinator.beginTransition(
            streamID: 27,
            transitionID: UUID(),
            target: activeTarget
        )
        coordinator.queueLatestTarget(queuedTarget)

        coordinator.clearAllState()

        #expect(coordinator.activeTransition == nil)
        #expect(coordinator.queuedTarget == nil)
        #expect(coordinator.latestRequestedTarget == nil)
        #expect(coordinator.lastSentTarget == nil)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)
    }
}
#endif
