//
//  DesktopStreamStartResetDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start reset decision coverage.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Desktop Stream Start Reset Decision")
struct DesktopStreamStartResetDecisionTests {

    @MainActor
    @Test("Desktop stop clears tracked token for stream")
    func desktopStopClearsTrackedToken() throws {
        let service = MirageClientService()
        let desktopSessionID = UUID()
        service.desktopSessionID = desktopSessionID
        service.desktopDimensionTokenByStream[9] = 22
        service.desktopDimensionTokenByStream[11] = 5

        let stopped = DesktopStreamStoppedMessage(
            streamID: 9,
            desktopSessionID: desktopSessionID,
            reason: .clientRequested
        )
        let envelope = try ControlMessage(type: .desktopStreamStopped, content: stopped)
        service.handleDesktopStreamStopped(envelope)

        #expect(service.desktopDimensionTokenByStream[9] == nil)
        #expect(service.desktopDimensionTokenByStream[11] == 5)
    }

    @MainActor
    @Test("Stale desktop resize commit does not mutate active transition state")
    func staleDesktopResizeCommitDoesNotMutateActiveTransitionState() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 17
        let initialResolution = CGSize(width: 1984, height: 2192)
        let activeTransitionID = UUID()
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamResolution = initialResolution
        service.desktopDimensionTokenByStream[streamID] = 4
        service.controllersByStream[streamID] = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: activeTransitionID,
            target: DesktopResizeCoordinator.RequestGeometry(
                logicalResolution: CGSize(width: 992, height: 1096),
                displayScaleFactor: 2.0,
                requestedStreamScale: 1.0,
                encoderMaxWidth: 2048,
                encoderMaxHeight: 1536
            )
        )

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let staleStarted = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: service.desktopSessionID!,
            width: 3200,
            height: 2400,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 3,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: UUID(),
            transitionPhase: .resize,
            transitionOutcome: .resized
        )
        let envelope = try ControlMessage(type: .desktopStreamStarted, content: staleStarted)

        await service.handleDesktopStreamStarted(envelope)

        #expect(service.desktopStreamResolution == initialResolution)
        #expect(service.desktopDimensionTokenByStream[streamID] == 4)
        #expect(service.desktopResizeCoordinator.activeTransition?.transitionID == activeTransitionID)
        #expect(callbackCount == 0)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Matching desktop resize commit updates resolution and begins post-resize gating")
    func matchingDesktopResizeCommitUpdatesResolutionAndBeginsPostResizeGating() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 23
        let transitionID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.controllersByStream[streamID] = controller
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: transitionID,
            target: DesktopResizeCoordinator.RequestGeometry(
                logicalResolution: CGSize(width: 1512, height: 982),
                displayScaleFactor: 2.0,
                requestedStreamScale: 1.0,
                encoderMaxWidth: 2360,
                encoderMaxHeight: 1640
            )
        )

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: service.desktopSessionID!,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: transitionID,
            transitionPhase: .resize,
            transitionOutcome: .resized
        )
        let envelope = try ControlMessage(type: .desktopStreamStarted, content: started)

        await service.handleDesktopStreamStarted(envelope)

        #expect(service.desktopStreamResolution == CGSize(width: 3024, height: 1964))
        #expect(service.desktopDimensionTokenByStream[streamID] == 8)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))

        await controller.stop()
    }

    @MainActor
    @Test("Rolled-back desktop resize with client fit fallback clears resize state")
    func rolledBackDesktopResizeWithClientFitFallbackClearsResizeState() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 24
        let transitionID = UUID()
        let desktopSessionID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        let activeTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1728, height: 1117),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 3456,
            encoderMaxHeight: 2234
        )
        let queuedTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1512, height: 982),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 3024,
            encoderMaxHeight: 1964
        )
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 3024, height: 1964)
        service.desktopStreamPresentationResolution = CGSize(width: 3024, height: 1964)
        service.controllersByStream[streamID] = controller
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: transitionID,
            target: activeTarget
        )
        service.desktopResizeCoordinator.queueLatestTarget(queuedTarget, dispatchPolicy: .settledWindowMetrics)
        service.sessionStore.beginPostResizeTransition(for: streamID)

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 9,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: transitionID,
            transitionPhase: .resize,
            transitionOutcome: .rolledBack,
            captureSource: .virtualDisplay,
            allowsClientResize: false,
            presentationWidth: 1512,
            presentationHeight: 982
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == CGSize(width: 3024, height: 1964))
        #expect(service.desktopStreamPresentationResolution == CGSize(width: 1512, height: 982))
        #expect(service.desktopCaptureSource == .virtualDisplay)
        #expect(!service.desktopStreamAllowsClientResize)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(!service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))

        await controller.stop()
    }

    @MainActor
    @Test("Stale transition UUID with older generation is ignored")
    func staleTransitionUUIDWithOlderGenerationIsIgnored() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 24
        let desktopSessionID = UUID()
        let activeTransitionID = UUID()
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.desktopPresentationGenerationBySessionID[desktopSessionID] = 4
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: activeTransitionID,
            target: DesktopResizeCoordinator.RequestGeometry(
                logicalResolution: CGSize(width: 1512, height: 982),
                displayScaleFactor: 2.0,
                requestedStreamScale: 1.0,
                encoderMaxWidth: 2360,
                encoderMaxHeight: 1640
            )
        )

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: UUID(),
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopPresentationGeneration: 3
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == CGSize(width: 1984, height: 2192))
        #expect(service.desktopPresentationGenerationBySessionID[desktopSessionID] == 4)
        #expect(service.desktopResizeCoordinator.activeTransition?.transitionID == activeTransitionID)
    }

    @MainActor
    @Test("Newer generation is accepted after local resize UI timeout clears transition")
    func newerGenerationAcceptedAfterLocalTimeoutClearsTransition() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 25
        let desktopSessionID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.desktopPresentationGenerationBySessionID[desktopSessionID] = 1
        service.controllersByStream[streamID] = controller
        service.desktopResizeCoordinator.clearLocalPresentationState()
        service.desktopResizeCoordinator.activeTransition = nil

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: UUID(),
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopPresentationGeneration: 2
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == CGSize(width: 3024, height: 1964))
        #expect(service.desktopDimensionTokenByStream[streamID] == 8)
        #expect(service.desktopPresentationGenerationBySessionID[desktopSessionID] == 2)

        await controller.stop()
    }

    @MainActor
    @Test("Non-transition desktop start token advance updates resolution and begins post-resize gating")
    func nonTransitionDesktopStartTokenAdvanceUpdatesResolutionAndBeginsPostResizeGating() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 27
        let desktopSessionID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.controllersByStream[streamID] = controller
        service.desktopDimensionTokenByStream[streamID] = 4

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 5,
            acceptedMediaMaxPacketSize: 1400
        )
        let envelope = try ControlMessage(type: .desktopStreamStarted, content: started)

        await service.handleDesktopStreamStarted(envelope)

        #expect(service.desktopStreamResolution == CGSize(width: 3024, height: 1964))
        #expect(service.desktopDimensionTokenByStream[streamID] == 5)
        #expect(service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))

        if let activeController = service.controllersByStream[streamID] {
            await activeController.stop()
        } else {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Same-geometry desktop token advance resets stream without post-resize gating")
    func sameGeometryDesktopTokenAdvanceResetsStreamWithoutPostResizeGating() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 32
        let desktopSessionID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 2448, height: 1408)
        service.desktopStreamPresentationResolution = CGSize(width: 2448, height: 1408)
        service.controllersByStream[streamID] = controller
        service.desktopDimensionTokenByStream[streamID] = 4

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2448,
            height: 1408,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 5,
            acceptedMediaMaxPacketSize: 1400,
            presentationWidth: 2448,
            presentationHeight: 1408
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == CGSize(width: 2448, height: 1408))
        #expect(service.desktopDimensionTokenByStream[streamID] == 5)
        #expect(!service.sessionStore.isAwaitingPostResizeFirstFrame(for: streamID))

        if let activeController = service.controllersByStream[streamID] {
            await activeController.stop()
        } else {
            await controller.stop()
        }
    }

    @Test("Desktop stream start geometry comparison distinguishes scale-only updates")
    func desktopStreamStartGeometryComparisonDistinguishesScaleOnlyUpdates() {
        #expect(
            !desktopStreamStartGeometryChanged(
                previousDisplaySize: CGSize(width: 2448, height: 1408),
                previousPresentationSize: CGSize(width: 2448, height: 1408),
                nextDisplaySize: CGSize(width: 2448, height: 1408),
                nextPresentationSize: CGSize(width: 2448, height: 1408)
            )
        )
        #expect(
            desktopStreamStartGeometryChanged(
                previousDisplaySize: CGSize(width: 2448, height: 1408),
                previousPresentationSize: CGSize(width: 2448, height: 1408),
                nextDisplaySize: CGSize(width: 2080, height: 1184),
                nextPresentationSize: CGSize(width: 2080, height: 1184)
            )
        )
    }

    @MainActor
    @Test("Accepted desktop startup preserves requested geometry before first frame metrics")
    func acceptedDesktopStartupPreservesRequestedGeometryBeforeFirstFrameMetrics() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 28
        let desktopSessionID = UUID()
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1366, height: 1024),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2048,
            encoderMaxHeight: 1536
        )
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2732,
            height: 2048,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            presentationWidth: 1366,
            presentationHeight: 1024
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)

        service.queueDesktopResize(
            streamID: streamID,
            target: startupTarget,
            hasPresentedFrame: false,
            useHostResolution: false
        )

        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(service.desktopResizeCoordinator.displayResolutionTask == nil)
        #expect(!service.desktopResizeCoordinator.isResizing)
        #expect(!service.desktopResizeCoordinator.maskActive)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Desktop start for a stopped session is ignored")
    func desktopStartForStoppedSessionIsIgnored() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 29
        let desktopSessionID = UUID()
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamMode = .unified
        service.desktopStreamResolution = CGSize(width: 2720, height: 2032)

        let stopped = DesktopStreamStoppedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            reason: .clientRequested
        )
        let stoppedEnvelope = try ControlMessage(type: .desktopStreamStopped, content: stopped)
        service.handleDesktopStreamStopped(stoppedEnvelope)

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let staleStarted = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2720,
            height: 2032,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 6,
            acceptedMediaMaxPacketSize: 1200,
            transitionPhase: .startup
        )
        let staleEnvelope = try ControlMessage(type: .desktopStreamStarted, content: staleStarted)
        await service.handleDesktopStreamStarted(staleEnvelope)

        #expect(service.retiredDesktopSessionIDs.contains(desktopSessionID))
        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.controllersByStream[streamID] == nil)
        #expect(callbackCount == 0)
    }

    @MainActor
    @Test("Late desktop stop for an old session is ignored after a new session starts")
    func lateDesktopStopForOldSessionIsIgnoredAfterNewSessionStarts() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 31
        let oldDesktopSessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let newDesktopSessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        service.desktopStreamID = streamID
        service.desktopSessionID = oldDesktopSessionID
        service.desktopStreamMode = .unified
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.controllersByStream[streamID] = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.pendingLocalDesktopStopStreamID = streamID
        service.pendingLocalDesktopStopSessionID = oldDesktopSessionID
        service.desktopDimensionTokenByStream[streamID] = 4
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()
        let sessionID = service.sessionStore.createSession(
            streamID: streamID,
            window: MirageWindow(
                id: 3101,
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
        service.sessionStore.markFirstFramePresented(for: streamID)

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: newDesktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup
        )
        let startedEnvelope = try ControlMessage(type: .desktopStreamStarted, content: started)
        await service.handleDesktopStreamStarted(startedEnvelope)

        let lateStopped = DesktopStreamStoppedMessage(
            streamID: streamID,
            desktopSessionID: oldDesktopSessionID,
            reason: .clientRequested
        )
        let stoppedEnvelope = try ControlMessage(type: .desktopStreamStopped, content: lateStopped)
        service.handleDesktopStreamStopped(stoppedEnvelope)

        #expect(service.desktopStreamID == streamID)
        #expect(service.desktopSessionID == newDesktopSessionID)
        #expect(service.desktopStreamResolution == CGSize(width: 3024, height: 1964))
        #expect(service.desktopDimensionTokenByStream[streamID] == 8)
        #expect(service.pendingLocalDesktopStopStreamID == nil)
        #expect(service.pendingLocalDesktopStopSessionID == nil)
        #expect(service.sessionStore.session(for: sessionID)?.hasDecodedFrame == false)
        #expect(service.sessionStore.session(for: sessionID)?.hasPresentedFrame == false)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }
}
#endif
