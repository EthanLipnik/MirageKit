//
//  DesktopResizeServiceTimeoutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing
import MirageCore

#if os(macOS)
@MainActor
extension DesktopResizeCoordinatorTests {
    @Test("Post-resize wait clears on presentation instead of decode")
    func postResizeWaitClearsOnPresentationInsteadOfDecode() {
        let service = MirageClientService()
        let streamID: StreamID = 43

        service.beginPostResizeTransition(streamID: streamID, scheduleTimeout: false)

        #expect(service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))

        service.handleStreamFirstFramePresented(streamID: streamID)

        #expect(!service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))
    }

    @Test("Post-resize wait timeout clears missing presentation signal")
    func postResizeWaitTimeoutClearsMissingPresentationSignal() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 44
        service.desktopPostResizeTransitionTimeout = .milliseconds(30)

        service.beginPostResizeTransition(streamID: streamID)

        let timeoutClearedPostResizeWait = await eventually {
            !service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID)
                && service.postResizeTransitionTimeoutTasks[streamID] == nil
        }
        #expect(timeoutClearedPostResizeWait)
    }

    @Test("Desktop resize mask timeout clears local blur state")
    func desktopResizeMaskTimeoutClearsLocalBlurState() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 46
        seedDesktopSession(service, streamID: streamID)
        service.desktopResizeWindowSettlingDelay = .seconds(1)
        service.desktopPostResizeTransitionTimeout = .milliseconds(30)

        service.queueDesktopResize(
            streamID: streamID,
            target: target(logicalWidth: 1408, logicalHeight: 898),
            hasPresentedFrame: true,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.maskActive)

        let timeoutClearedLocalMask = await eventually {
            !service.desktopResizeCoordinator.isResizing
                && !service.desktopResizeCoordinator.maskActive
        }
        #expect(timeoutClearedLocalMask)
        service.clearDesktopResizeState(streamID: streamID)
    }

    @Test("Automatic workload resize bypasses window settle policy")
    func automaticWorkloadResizeBypassesWindowSettlePolicy() {
        let service = MirageClientService()
        let streamID: StreamID = 47
        seedDesktopSession(service, streamID: streamID)
        service.desktopResizeWindowSettlingDelay = .seconds(60)
        let resizeTarget = target(logicalWidth: 1280, logicalHeight: 720)

        service.queueDesktopResize(
            streamID: streamID,
            target: resizeTarget,
            hasPresentedFrame: true,
            useHostResolution: false,
            dispatchPolicy: .immediate
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == resizeTarget)
        #expect(service.desktopResizeCoordinator.queuedDispatchPolicy == .immediate)
        #expect(service.desktopResizeCoordinator.displayResolutionTask != nil)
        service.clearDesktopResizeState(streamID: streamID)
    }
}
#endif
