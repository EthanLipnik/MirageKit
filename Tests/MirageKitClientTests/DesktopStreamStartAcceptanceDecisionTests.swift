//
//  DesktopStreamStartAcceptanceDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start acceptance coverage.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Desktop Stream Start Acceptance Decision")
struct DesktopStreamStartAcceptanceDecisionTests {
    @Test("Same-stream route replacement token advance is accepted as in-place reset")
    func sameStreamRouteReplacementTokenAdvanceIsAcceptedAsInPlaceReset() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 42,
            previousStreamID: 42,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 7,
            receivedDimensionToken: 8
        )

        #expect(decision == .acceptResizeAdvance)
    }

    @Test("Same-stream route replacement duplicate token is rejected")
    func sameStreamRouteReplacementDuplicateTokenIsRejected() {
        let decision = desktopStreamStartAcceptanceDecision(
            streamID: 42,
            previousStreamID: 42,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 7,
            receivedDimensionToken: 7
        )

        #expect(decision == .ignoreDuplicateToken)
    }

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
    @Test("Stale desktop resize geometry contract does not mutate active transition state")
    func staleDesktopResizeGeometryContractDoesNotMutateActiveTransitionState() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 18
        let initialResolution = CGSize(width: 1984, height: 2192)
        let activeTransitionID = UUID()
        let activeContractID = UUID()
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamResolution = initialResolution
        service.desktopDimensionTokenByStream[streamID] = 4
        service.controllersByStream[streamID] = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: activeTransitionID,
            target: DesktopResizeCoordinator.RequestGeometry(
                contractID: activeContractID,
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
            width: 2048,
            height: 1536,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 5,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: activeTransitionID,
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopGeometryContractID: UUID()
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: staleStarted))

        #expect(service.desktopStreamResolution == initialResolution)
        #expect(service.desktopDimensionTokenByStream[streamID] == 4)
        #expect(service.desktopResizeCoordinator.activeTransition?.transitionID == activeTransitionID)
        #expect(service.desktopResizeCoordinator.activeTransition?.target.contractID == activeContractID)
        #expect(callbackCount == 0)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Desktop resize commit with matching contract ID accepts host-owned pixels")
    func desktopResizeCommitWithMatchingContractIDAcceptsHostOwnedPixels() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 19
        let initialResolution = CGSize(width: 1984, height: 2192)
        let activeTransitionID = UUID()
        let activeContractID = UUID()
        let target = DesktopResizeCoordinator.RequestGeometry(
            contractID: activeContractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 45,
            logicalResolution: CGSize(width: 1024, height: 768),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2048,
            encoderMaxHeight: 1536
        )
        let hostDisplayPixelSize = CGSize(width: 1536, height: 1152)
        let hostEncodedPixelSize = CGSize(width: 1280, height: 960)
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamResolution = initialResolution
        service.desktopDimensionTokenByStream[streamID] = 4
        service.controllersByStream[streamID] = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopResizeCoordinator.beginTransition(
            streamID: streamID,
            transitionID: activeTransitionID,
            target: target
        )

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: service.desktopSessionID!,
            width: Int(hostEncodedPixelSize.width),
            height: Int(hostEncodedPixelSize.height),
            frameRate: 45,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 5,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: activeTransitionID,
            transitionPhase: .resize,
            transitionOutcome: .resized,
            acceptedDisplayScaleFactor: nil,
            presentationWidth: Int(target.logicalResolution.width),
            presentationHeight: Int(target.logicalResolution.height),
            desktopGeometryContractID: activeContractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: Int(hostDisplayPixelSize.width),
            desktopGeometryDisplayPixelHeight: Int(hostDisplayPixelSize.height),
            desktopGeometryEncodedPixelWidth: Int(hostEncodedPixelSize.width),
            desktopGeometryEncodedPixelHeight: Int(hostEncodedPixelSize.height),
            desktopGeometryRefreshTargetHz: 45
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == hostEncodedPixelSize)
        #expect(service.desktopStreamPresentationResolution == target.logicalResolution)
        #expect(abs((service.desktopStreamDisplayScaleFactor ?? 0) - 1.5) < 0.001)
        #expect(service.desktopDimensionTokenByStream[streamID] == 5)
        #expect(service.desktopResizeCoordinator.activeTransition == nil)
        #expect(callbackCount == 1)

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
    @Test("Newer generation without contract is ignored during different active transition")
    func newerGenerationWithoutContractIgnoredDuringDifferentActiveTransition() async throws {
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
            desktopPresentationGeneration: 5
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
    @Test("Generation resize commit with matching geometry contract is accepted without active transition")
    func generationResizeCommitWithMatchingGeometryContractAcceptedWithoutActiveTransition() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 31
        let desktopSessionID = UUID()
        let contractID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        let target = DesktopResizeCoordinator.RequestGeometry(
            contractID: contractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 45,
            logicalResolution: CGSize(width: 1512, height: 982),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2360,
            encoderMaxHeight: 1640
        )
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: target.logicalResolution,
            displayScaleFactor: target.displayScaleFactor,
            requestedStreamScale: target.requestedStreamScale,
            encoderMaxWidth: target.encoderMaxWidth,
            encoderMaxHeight: target.encoderMaxHeight
        )
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.desktopPresentationGenerationBySessionID[desktopSessionID] = 1
        service.controllersByStream[streamID] = controller
        service.desktopResizeCoordinator.lastSentTarget = target

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(geometry.displayPixelSize.width),
            height: Int(geometry.displayPixelSize.height),
            frameRate: 45,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: UUID(),
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopPresentationGeneration: 2,
            acceptedDisplayScaleFactor: 2.0,
            presentationWidth: Int(target.logicalResolution.width),
            presentationHeight: Int(target.logicalResolution.height),
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: Int(geometry.displayPixelSize.width),
            desktopGeometryDisplayPixelHeight: Int(geometry.displayPixelSize.height),
            desktopGeometryEncodedPixelWidth: Int(geometry.encodedPixelSize.width),
            desktopGeometryEncodedPixelHeight: Int(geometry.encodedPixelSize.height),
            desktopGeometryRefreshTargetHz: 45
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == geometry.displayPixelSize)
        #expect(service.desktopDimensionTokenByStream[streamID] == 8)
        #expect(service.desktopPresentationGenerationBySessionID[desktopSessionID] == 2)

        await controller.stop()
    }

    @MainActor
    @Test("Generation resize commit with stale geometry contract is ignored without active transition")
    func generationResizeCommitWithStaleGeometryContractIgnoredWithoutActiveTransition() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 32
        let desktopSessionID = UUID()
        let contractID = UUID()
        let controller = StreamController(streamID: streamID, maxPayloadSize: 1200)
        service.desktopStreamID = streamID
        service.desktopSessionID = desktopSessionID
        service.desktopStreamResolution = CGSize(width: 1984, height: 2192)
        service.desktopPresentationGenerationBySessionID[desktopSessionID] = 1
        service.controllersByStream[streamID] = controller
        service.desktopResizeCoordinator.lastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: contractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 45,
            logicalResolution: CGSize(width: 1512, height: 982),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2360,
            encoderMaxHeight: 1640
        )

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 45,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 8,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: UUID(),
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopPresentationGeneration: 2,
            desktopGeometryContractID: UUID(),
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryRefreshTargetHz: 45
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamResolution == CGSize(width: 1984, height: 2192))
        #expect(service.desktopDimensionTokenByStream[streamID] == nil)
        #expect(service.desktopPresentationGenerationBySessionID[desktopSessionID] == 1)

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
    @Test("App-stream placeholder desktop startup clears client minimum size")
    func appStreamPlaceholderDesktopStartupClearsClientMinimumSize() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 29
        let desktopSessionID = UUID()
        let appSessionID = UUID()
        var desktopStartCallbackSize: CGSize?
        var minimumSizeCallbackCalled = false
        service.onDesktopStreamStarted = { streamID, minimumSize, _ in
            desktopStartCallbackSize = minimumSize
            let window = MirageWindow(
                id: 0,
                title: "Desktop",
                application: nil,
                frame: CGRect(origin: .zero, size: minimumSize),
                isOnScreen: true,
                windowLayer: 0
            )
            service.sessionStore.registerSession(
                streamID: streamID,
                mediaStreamID: streamID,
                window: window,
                hostName: "Host",
                minSize: minimumSize
            )
        }
        service.onStreamMinimumSizeUpdate = { _, _ in
            minimumSizeCallbackCalled = true
        }

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
            presentationHeight: 1024,
            presentationRole: .appStreamPlaceholder,
            associatedAppSessionID: appSessionID,
            associatedBundleIdentifier: "com.example.App"
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        let session = try #require(service.sessionStore.sessionByStreamID(streamID))
        #expect(service.appStreamPlaceholderDesktopStreamID == streamID)
        #expect(service.appStreamPlaceholderAppSessionID == appSessionID)
        #expect(service.desktopStreamMode == .secondary)
        #expect(desktopStartCallbackSize == CGSize(width: 1366, height: 1024))
        #expect(!minimumSizeCallbackCalled)
        #expect(service.sessionStore.sessionMinSizes[session.id] == nil)
        #expect(session.minWidth == 400)
        #expect(session.minHeight == 300)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Stale desktop startup geometry contract is ignored")
    func staleDesktopStartupGeometryContractIsIgnored() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 32
        let expectedContractID = UUID()
        service.desktopResizeCoordinator.lastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: expectedContractID,
            logicalResolution: CGSize(width: 1366, height: 1024),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2732,
            encoderMaxHeight: 2048
        )
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: UUID(),
            width: 2048,
            height: 1536,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            presentationWidth: 1366,
            presentationHeight: 1024,
            desktopGeometryContractID: UUID()
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamRequestStartTime > 0)
        #expect(service.desktopResizeCoordinator.lastSentTarget?.contractID == expectedContractID)
        #expect(service.controllersByStream[streamID] == nil)
        #expect(callbackCount == 0)
    }

    @MainActor
    @Test("AWDL desktop startup without contract rejects size mismatch")
    func awdlDesktopStartupWithoutContractRejectsSizeMismatch() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 36
        let expectedContractID = UUID()
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: expectedContractID,
            logicalResolution: CGSize(width: 1366, height: 1024),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2732,
            encoderMaxHeight: 2048
        )
        service.handleControlPathUpdate(Self.awdlRadioSnapshot())
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: UUID(),
            width: 2048,
            height: 1536,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            presentationWidth: 1024,
            presentationHeight: 768
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamRequestStartTime > 0)
        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)
        #expect(callbackCount == 0)
    }

    @MainActor
    @Test("AWDL desktop startup without contract rejects matching geometry")
    func awdlDesktopStartupWithoutContractRejectsMatchingGeometry() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 37
        let desktopSessionID = UUID()
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1024, height: 768),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        service.handleControlPathUpdate(Self.awdlRadioSnapshot())
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2048,
            height: 1536,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            acceptedDisplayScaleFactor: 2.0,
            presentationWidth: 1024,
            presentationHeight: 768
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamResolution == nil)
        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)
        #expect(service.desktopStreamRequestStartTime > 0)
        #expect(callbackCount == 0)
    }

    @MainActor
    @Test("Contract-bearing desktop startup without expected target is ignored")
    func contractBearingDesktopStartupWithoutExpectedTargetIsIgnored() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 33
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: UUID(),
            width: 2732,
            height: 2048,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            acceptedDisplayScaleFactor: 2.0,
            presentationWidth: 1024,
            presentationHeight: 768,
            desktopGeometryContractID: UUID(),
            desktopGeometryDisplayPixelWidth: 2048,
            desktopGeometryDisplayPixelHeight: 1536,
            desktopGeometryEncodedPixelWidth: 2048,
            desktopGeometryEncodedPixelHeight: 1536,
            desktopGeometryRefreshTargetHz: 60
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamRequestStartTime > 0)
        #expect(callbackCount == 0)
    }

    @MainActor
    @Test("Desktop startup geometry contract accepts host-owned final geometry")
    func desktopStartupGeometryContractAcceptsHostOwnedFinalGeometry() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 34
        let contractID = UUID()
        let desktopSessionID = UUID()
        let hostDisplayPixelSize = CGSize(width: 1248, height: 2720)
        let hostDisplayScaleFactor: CGFloat = 2.971
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: contractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 60,
            logicalResolution: CGSize(width: 420, height: 912),
            displayScaleFactor: 3.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(hostDisplayPixelSize.width),
            height: Int(hostDisplayPixelSize.height),
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            acceptedDisplayScaleFactor: hostDisplayScaleFactor,
            presentationWidth: Int(startupTarget.logicalResolution.width),
            presentationHeight: Int(startupTarget.logicalResolution.height),
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: Int(hostDisplayPixelSize.width),
            desktopGeometryDisplayPixelHeight: Int(hostDisplayPixelSize.height),
            desktopGeometryEncodedPixelWidth: Int(hostDisplayPixelSize.width),
            desktopGeometryEncodedPixelHeight: Int(hostDisplayPixelSize.height),
            desktopGeometryRefreshTargetHz: 60
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == streamID)
        #expect(service.desktopSessionID == desktopSessionID)
        #expect(service.desktopStreamResolution == hostDisplayPixelSize)
        #expect(service.desktopStreamPresentationResolution == startupTarget.logicalResolution)
        #expect(abs((service.desktopStreamDisplayScaleFactor ?? 0) - hostDisplayScaleFactor) < 0.001)
        #expect(service.desktopStreamRequestStartTime == 0)
        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)
        #expect(callbackCount == 1)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Matching desktop startup geometry contract is accepted")
    func matchingDesktopStartupGeometryContractIsAccepted() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 35
        let contractID = UUID()
        let desktopSessionID = UUID()
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            contractID: contractID,
            sceneIdentity: "scene-a",
            refreshTargetHz: 60,
            logicalResolution: CGSize(width: 1024, height: 768),
            displayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        var callbackCount = 0
        service.onDesktopStreamStarted = { _, _, _ in
            callbackCount += 1
        }

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2048,
            height: 1536,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            acceptedDisplayScaleFactor: 2.0,
            presentationWidth: 1024,
            presentationHeight: 768,
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: 2048,
            desktopGeometryDisplayPixelHeight: 1536,
            desktopGeometryEncodedPixelWidth: 2048,
            desktopGeometryEncodedPixelHeight: 1536,
            desktopGeometryRefreshTargetHz: 60
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamID == streamID)
        #expect(service.desktopSessionID == desktopSessionID)
        #expect(service.desktopStreamResolution == CGSize(width: 2048, height: 1536))
        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)
        #expect(service.desktopStreamRequestStartTime == 0)
        #expect(callbackCount == 1)

        if let controller = service.controllersByStream[streamID] {
            await controller.stop()
        }
    }

    @MainActor
    @Test("Accepted desktop startup scale clears matching queued resize and blocks one-x downgrade")
    func acceptedDesktopStartupScaleClearsMatchingQueuedResizeAndBlocksOneXDowngrade() async throws {
        let service = MirageClientService()
        let streamID: StreamID = 30
        let desktopSessionID = UUID()
        let startupTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        let matchingQueuedTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        service.desktopResizeCoordinator.lastSentTarget = startupTarget
        service.desktopResizeCoordinator.queueLatestTarget(matchingQueuedTarget)
        service.desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        let started = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: 2752,
            height: 2064,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 1,
            acceptedMediaMaxPacketSize: 1400,
            transitionPhase: .startup,
            acceptedDisplayScaleFactor: 1.72,
            presentationWidth: 1600,
            presentationHeight: 1200
        )

        await service.handleDesktopStreamStarted(try ControlMessage(type: .desktopStreamStarted, content: started))

        #expect(service.desktopStreamDisplayScaleFactor == 1.72)
        #expect(service.desktopResizeCoordinator.lastSentTarget == startupTarget)
        #expect(service.desktopResizeCoordinator.queuedTarget == nil)
        #expect(service.desktopResizeCoordinator.latestRequestedTarget == nil)

        service.sessionStore.registerSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageWindow(
                id: WindowID(streamID),
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

        let oneXDowngrade = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: nil,
            encoderMaxHeight: nil
        )
        service.queueDesktopResize(
            streamID: streamID,
            target: oneXDowngrade,
            hasPresentedFrame: true,
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
            mediaStreamID: streamID,
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

    private static func awdlRadioSnapshot() -> MirageNetworkPathSnapshot {
        MirageNetworkPathClassifier.classify(
            interfaceNames: ["awdl0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
    }
}
#endif
