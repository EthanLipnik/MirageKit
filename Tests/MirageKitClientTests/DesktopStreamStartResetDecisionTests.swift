//
//  DesktopStreamStartResetDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start reset decision coverage.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Stream Start Reset Decision")
struct DesktopStreamStartResetDecisionTests {
    @Test("Desktop start accepts token advance for active stream")
    func desktopStartAcceptsTokenAdvanceForActiveStream() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 13
        )

        #expect(decision == .acceptResizeAdvance)
    }

    @Test("Desktop start ignores duplicate token for active stream")
    func desktopStartIgnoresDuplicateTokenForActiveStream() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 12
        )

        #expect(decision == .ignoreDuplicateToken)
    }

    @Test("Desktop start ignores older token for active stream")
    func desktopStartIgnoresOlderTokenForActiveStream() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 11
        )

        #expect(decision == .ignoreOlderToken)
    }

    @Test("Desktop start ignores missing token after tokenized stream has started")
    func desktopStartIgnoresMissingTokenAfterTokenizedStreamHasStarted() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: nil
        )

        #expect(decision == .ignoreMissingTokenAfterTokenizedStart)
    }

    @Test("Initial desktop start resets controller")
    func initialDesktopStartResetsController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: nil,
            hasController: false,
            requestStartPending: false,
            previousDimensionToken: nil,
            receivedDimensionToken: 0
        )

        #expect(decision == .resetController)
    }

    @Test("Same stream and token reuses controller")
    func sameStreamSameTokenReusesController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 12
        )

        #expect(decision == .reuseController)
    }

    @Test("Same stream with changed token resets controller")
    func sameStreamChangedTokenResetsController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 13
        )

        #expect(decision == .resetController)
    }

    @MainActor
    @Test("Desktop stop clears tracked token for stream")
    func desktopStopClearsTrackedToken() throws {
        let service = MirageClientService()
        service.desktopDimensionTokenByStream[9] = 22
        service.desktopDimensionTokenByStream[11] = 5

        let stopped = DesktopStreamStoppedMessage(streamID: 9, reason: .clientRequested)
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
}
#endif
