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
    func target(
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

    func seedDesktopSession(
        _ service: MirageClientService,
        streamID: StreamID
    ) {
        service.desktopStreamID = streamID
        service.sessionStore.registerSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageWindow(
                id: WindowID(streamID),
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1366, height: 1024),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
    }

    func eventually(
        attempts: Int = 100,
        interval: Duration = .milliseconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0 ..< max(1, attempts) {
            if condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    @Test("Desktop resize target honors explicit drawable scale")
    func desktopResizeTargetHonorsExplicitDrawableScale() throws {
        let service = MirageClientService()

        let oneXTarget = try #require(
            service.desktopResizeTarget(
                for: CGSize(width: 1200, height: 800),
                maxDrawableSize: nil,
                displayScaleFactor: 1.0
            )
        )
        let retinaTarget = try #require(
            service.desktopResizeTarget(
                for: CGSize(width: 1200, height: 800),
                maxDrawableSize: nil,
                displayScaleFactor: 2.0
            )
        )

        #expect(oneXTarget.displayScaleFactor == 1.0)
        #expect(retinaTarget.displayScaleFactor == 2.0)
        #expect(oneXTarget.logicalResolution == retinaTarget.logicalResolution)
        #expect(!oneXTarget.isEffectivelySameStreamGeometry(as: retinaTarget))
    }

    @Test("Contract equality ignores raw stream scale when resolved geometry matches")
    func contractEqualityIgnoresRawStreamScaleWhenResolvedGeometryMatches() {
        let startup = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        let firstDrawable = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 2.0,
            requestedStreamScale: 0.86,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )

        #expect(startup.isEffectivelySameStreamGeometry(as: firstDrawable))
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

        coordinator.finishTransition()

        #expect(coordinator.activeTransition == nil)
        #expect(coordinator.queuedTarget == queuedTarget)
        #expect(coordinator.latestRequestedTarget == queuedTarget)
        #expect(coordinator.isResizing)
        #expect(coordinator.maskActive)
    }

    @Test("Accepted startup geometry clears duplicate queued resize")
    func acceptedStartupGeometryClearsDuplicateQueuedResize() {
        let coordinator = DesktopResizeCoordinator()
        let duplicateTarget = target(logicalWidth: 1600, logicalHeight: 1200)
        let nextTarget = target(logicalWidth: 1512, logicalHeight: 982)
        coordinator.queueLatestTarget(duplicateTarget)
        coordinator.isResizing = true
        coordinator.maskActive = true

        coordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayPixelSize: CGSize(width: 3200, height: 2400)
        )

        #expect(coordinator.queuedTarget == nil)
        #expect(coordinator.latestRequestedTarget == nil)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)

        coordinator.queueLatestTarget(nextTarget)
        coordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayPixelSize: CGSize(width: 3200, height: 2400)
        )

        #expect(coordinator.queuedTarget == nextTarget)
        #expect(coordinator.latestRequestedTarget == nextTarget)
    }

    @Test("Local timeout clears presentation UI but preserves active transition")
    func localTimeoutClearsPresentationUIButPreservesActiveTransition() {
        let coordinator = DesktopResizeCoordinator()
        let transitionID = UUID()
        let activeTarget = target()
        let queuedTarget = target(logicalWidth: 1512, logicalHeight: 982)
        coordinator.beginTransition(
            streamID: 23,
            transitionID: transitionID,
            target: activeTarget
        )
        coordinator.queueLatestTarget(queuedTarget)

        coordinator.clearLocalPresentationState()

        #expect(
            coordinator.activeTransition == DesktopResizeCoordinator.ActiveTransition(
                streamID: 23,
                transitionID: transitionID,
                target: activeTarget
            )
        )
        #expect(coordinator.queuedTarget == queuedTarget)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)
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

    @Test("Clear-all-state can preserve suspended lifecycle")
    func clearAllStateCanPreserveSuspendedLifecycle() {
        let coordinator = DesktopResizeCoordinator()
        coordinator.resizeLifecycleState = .suspended
        coordinator.beginTransition(
            streamID: 31,
            transitionID: UUID(),
            target: target()
        )

        coordinator.clearAllState(preserveLifecycleState: true)

        #expect(coordinator.resizeLifecycleState == .suspended)
        #expect(coordinator.activeTransition == nil)
        #expect(coordinator.queuedTarget == nil)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)
    }

    @Test("Lifecycle suspension can preserve last sent target while clearing queued resize")
    func lifecycleSuspensionCanPreserveLastSentTargetWhileClearingQueuedResize() {
        let coordinator = DesktopResizeCoordinator()
        let lastSentTarget = target()
        let queuedTarget = target(logicalWidth: 1512, logicalHeight: 982)

        coordinator.lastSentTarget = lastSentTarget
        coordinator.queueLatestTarget(queuedTarget)
        coordinator.isResizing = true
        coordinator.maskActive = true

        coordinator.clearAllState(
            preserveLifecycleState: true,
            preserveLastSentTarget: true
        )

        #expect(coordinator.lastSentTarget == lastSentTarget)
        #expect(coordinator.queuedTarget == nil)
        #expect(coordinator.latestRequestedTarget == nil)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)
    }

    @Test("Cancel pending dispatch keeps latest target for lifecycle gates")
    func cancelPendingDispatchKeepsLatestTargetForLifecycleGates() {
        let coordinator = DesktopResizeCoordinator()
        let queuedTarget = target(logicalWidth: 1512, logicalHeight: 982)

        coordinator.queueLatestTarget(queuedTarget)
        coordinator.isResizing = true
        coordinator.maskActive = true

        coordinator.cancelPendingResizeDispatch()

        #expect(coordinator.queuedTarget == queuedTarget)
        #expect(coordinator.latestRequestedTarget == queuedTarget)
        #expect(!coordinator.isResizing)
        #expect(!coordinator.maskActive)
    }

    @Test("Startup desktop resize requests coalesce until first presented frame")
    func startupDesktopResizeRequestsCoalesceUntilFirstPresentedFrame() {
        let service = MirageClientService()
        let streamID: StreamID = 37
        let firstTarget = target(logicalWidth: 1366, logicalHeight: 1024)
        let secondTarget = target(logicalWidth: 1512, logicalHeight: 982)

        service.queueDesktopResize(
            streamID: streamID,
            target: firstTarget,
            hasPresentedFrame: false,
            useHostResolution: false
        )
        service.queueDesktopResize(
            streamID: streamID,
            target: secondTarget,
            hasPresentedFrame: false,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == secondTarget)
        #expect(service.desktopResizeCoordinator.latestRequestedTarget == secondTarget)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.displayResolutionTask == nil)
        #expect(!service.desktopResizeCoordinator.isResizing)
        #expect(!service.desktopResizeCoordinator.maskActive)
    }

    @Test("No-op desktop resize is suppressed even while client recovery is active")
    func noOpDesktopResizeIsSuppressedDuringClientRecovery() {
        let service = MirageClientService()
        let streamID: StreamID = 38
        let target = target(logicalWidth: 1366, logicalHeight: 1024)
        service.desktopResizeCoordinator.lastSentTarget = target
        service.sessionStore.registerSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageWindow(
                id: 9001,
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1366, height: 1024),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
        service.sessionStore.setClientRecoveryStatus(for: streamID, status: .startup)

        service.queueDesktopResize(
            streamID: streamID,
            target: target,
            hasPresentedFrame: true,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.displayResolutionTask == nil)
        #expect(!service.desktopResizeCoordinator.isResizing)
        #expect(!service.desktopResizeCoordinator.maskActive)
    }

    @Test("No-op startup resize is suppressed when encoder cap matches uncapped output")
    func noOpStartupResizeIsSuppressedWhenEncoderCapMatchesUncappedOutput() {
        let service = MirageClientService()
        let streamID: StreamID = 39
        let uncappedStartupTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        let drawableBoundTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        service.desktopResizeCoordinator.lastSentTarget = uncappedStartupTarget
        service.sessionStore.registerSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageWindow(
                id: 9002,
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
        service.sessionStore.setClientRecoveryStatus(for: streamID, status: .startup)

        service.queueDesktopResize(
            streamID: streamID,
            target: drawableBoundTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )

        #expect(uncappedStartupTarget.isEffectivelySameStreamGeometry(as: drawableBoundTarget))
        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.displayResolutionTask == nil)
        #expect(!service.desktopResizeCoordinator.isResizing)
        #expect(!service.desktopResizeCoordinator.maskActive)
    }

    @Test("Window-driven desktop resize targets settle before dispatch")
    func windowDrivenDesktopResizeTargetsSettleBeforeDispatch() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 40
        seedDesktopSession(service, streamID: streamID)
        service.desktopResizeWindowSettlingDelay = .milliseconds(200)
        let firstTarget = target(logicalWidth: 1408, logicalHeight: 898)
        let secondTarget = target(logicalWidth: 1406, logicalHeight: 968)

        service.queueDesktopResize(
            streamID: streamID,
            target: firstTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )
        service.queueDesktopResize(
            streamID: streamID,
            target: secondTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == secondTarget)
        #expect(service.desktopResizeCoordinator.queuedDispatchPolicy == .settledWindowMetrics)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.isResizing)
        #expect(service.desktopResizeCoordinator.maskActive)

        try await Task.sleep(for: .milliseconds(50))

        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        service.clearDesktopResizeState(streamID: streamID)
    }

    @Test("Returning to last sent desktop geometry clears pending mask")
    func returningToLastSentDesktopGeometryClearsPendingMask() {
        let service = MirageClientService()
        let streamID: StreamID = 41
        seedDesktopSession(service, streamID: streamID)
        let lastSentTarget = target(logicalWidth: 1406, logicalHeight: 968)
        let pendingTarget = target(logicalWidth: 1408, logicalHeight: 898)
        service.desktopResizeCoordinator.lastSentTarget = lastSentTarget

        service.queueDesktopResize(
            streamID: streamID,
            target: pendingTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )
        #expect(service.desktopResizeCoordinator.maskActive)

        service.queueDesktopResize(
            streamID: streamID,
            target: lastSentTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(service.desktopResizeCoordinator.latestRequestedTarget == nil)
        #expect(service.desktopResizeCoordinator.displayResolutionTask == nil)
        #expect(!service.desktopResizeCoordinator.isResizing)
        #expect(!service.desktopResizeCoordinator.maskActive)
    }

    @Test("Queued desktop resize after transition waits for settle delay")
    func queuedDesktopResizeAfterTransitionWaitsForSettleDelay() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 42
        seedDesktopSession(service, streamID: streamID)
        service.desktopResizeWindowSettlingDelay = .milliseconds(200)
        let activeTarget = target(logicalWidth: 1408, logicalHeight: 898)
        let queuedTarget = target(logicalWidth: 1406, logicalHeight: 968)

        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: UUID(),
            target: activeTarget
        )
        service.queueDesktopResize(
            streamID: streamID,
            target: queuedTarget,
            hasPresentedFrame: true,
            useHostResolution: false
        )
        service.desktopResizeCoordinator.finishTransition()
        service.handleDesktopPresentationReady(streamID: streamID)
        await Task.yield()

        #expect(service.desktopResizeCoordinator.displayResolutionTask != nil)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.desktopResizeCoordinator.activeTransition == nil)

        service.clearDesktopResizeState(streamID: streamID)
    }

}
#endif
