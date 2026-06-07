//
//  AppResizeAcknowledgementTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/27/26.
//

@testable import MirageKitClient
import Testing
import CoreGraphics
import MirageCore
import MirageKit
import MirageMedia
import MirageWire

@Suite("App Resize Acknowledgement")
struct AppResizeAcknowledgementTests {
    @MainActor
    @Test("App resize ack resolves through shared media stream")
    func resolvesAcknowledgementThroughSharedMediaStream() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService()
        let sessionID = store.createSession(
            streamID: 101,
            mediaStreamID: 100,
            window: MirageMedia.MirageWindow(
                id: 10101,
                title: "Logical App Window",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))
        let acknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 1280,
            height: 720,
            dimensionToken: 42
        )
        service.appStreamStartAcknowledgementByStreamID[100] = acknowledgement

        let view = MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service
        )

        #expect(view.appStreamStartAcknowledgement == acknowledgement)
    }

    @MainActor
    @Test("App atlas presentation binds logical stream before layout arrives")
    func appAtlasPresentationBindsLogicalStreamBeforeLayoutArrives() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService()
        let sessionID = store.createSession(
            streamID: 111,
            mediaStreamID: 110,
            window: MirageMedia.MirageWindow(
                id: 11101,
                title: "Logical App Window",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            atlasRegion: nil,
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))

        let view = MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service
        )

        #expect(view.presentationStreamID == 111)
        #expect(view.presentationContentRectOverride == nil)
    }

    @MainActor
    @Test("App resize result updates logical state without overwriting media dimensions")
    func resizeResultDoesNotOverwriteMediaDimensions() throws {
        let service = MirageClientService()
        let mediaAcknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 2320,
            height: 1792,
            dimensionToken: 12
        )
        service.appStreamStartAcknowledgementByStreamID[200] = mediaAcknowledgement
        service.appDimensionTokenByStream[200] = 12
        let result = MirageWire.AppWindowResizeResultMessage(
            streamID: 201,
            mediaStreamID: 200,
            windowID: 20101,
            outcome: .applied,
            requestedWidth: 1156,
            requestedHeight: 892,
            observedWidth: 1156,
            observedHeight: 892,
            minWidth: nil,
            minHeight: nil,
            reason: nil
        )

        service.handleAppWindowResizeResult(try MirageWire.ControlMessage(type: .appWindowResizeResult, content: result))

        #expect(service.appStreamStartAcknowledgementByStreamID[200] == mediaAcknowledgement)
        #expect(service.appStreamStartAcknowledgementByStreamID[201]?.width == 1156)
        #expect(service.appStreamStartAcknowledgementByStreamID[201]?.height == 892)
        #expect(service.appStreamStartAcknowledgementByStreamID[201]?.dimensionToken == 12)
        #expect(service.appWindowResizeResultByStreamID[201] == result)
        #expect(service.appWindowResizeResultByStreamID[200] == nil)
    }

    @MainActor
    @Test("App resize result clears resize wait")
    func appResizeResultClearsResizeWait() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService()
        let sessionID = store.createSession(
            streamID: 121,
            mediaStreamID: 120,
            window: MirageMedia.MirageWindow(
                id: 12101,
                title: "Logical App Window",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))
        let view = MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service
        )

        view.appResizeDispatchState.enqueue(CGSize(width: 900, height: 700))
        _ = view.appResizeDispatchState.beginNextDispatch(now: 0)
        view.beginAppResizeAwaitingAck()
        let result = MirageWire.AppWindowResizeResultMessage(
            streamID: 121,
            mediaStreamID: 120,
            windowID: 12101,
            outcome: .failed,
            requestedWidth: 900,
            requestedHeight: 700,
            observedWidth: 640,
            observedHeight: 480,
            minWidth: nil,
            minHeight: nil,
            reason: "setAttributeFailed"
        )

        view.handleAppWindowResizeResult(result)

        #expect(!view.awaitingAppResizeAck)
        #expect(!view.isResizing)
    }

    @MainActor
    @Test("App resize result minimum size requires matched failed shrink")
    func appResizeResultMinimumSizeRequiresMatchedFailedShrink() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService(sessionStore: store)
        let sessionID = store.createSession(
            streamID: 131,
            mediaStreamID: 130,
            window: MirageWindow(
                id: 13101,
                title: "Logical App Window",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))
        let view = MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service
        )

        let failedGrowResult = appResizeResult(
            streamID: 131,
            mediaStreamID: 130,
            windowID: 13101,
            outcome: .failed,
            requestedSize: CGSize(width: 900, height: 700),
            observedSize: CGSize(width: 640, height: 480),
            minSize: CGSize(width: 640, height: 480),
            reason: "didNotConverge"
        )
        view.applyLearnedMinimumSizeIfNeeded(
            from: failedGrowResult,
            inFlightTarget: CGSize(width: 900, height: 700)
        )

        #expect(store.sessionMinSizes[sessionID] == nil)
        #expect(store.session(for: sessionID)?.minWidth == 400)
        #expect(store.session(for: sessionID)?.minHeight == 300)

        let failedShrinkResult = appResizeResult(
            streamID: 131,
            mediaStreamID: 130,
            windowID: 13101,
            outcome: .failed,
            requestedSize: CGSize(width: 500, height: 360),
            observedSize: CGSize(width: 640, height: 480),
            minSize: CGSize(width: 640, height: 480),
            reason: "didNotConverge"
        )
        view.applyLearnedMinimumSizeIfNeeded(
            from: failedShrinkResult,
            inFlightTarget: CGSize(width: 500, height: 360)
        )

        #expect(store.sessionMinSizes[sessionID] == CGSize(width: 640, height: 480))
        #expect(store.sessionMinSizeUpdateGenerations[sessionID] == 1)
    }

    @MainActor
    @Test("Locked-login resize result does not update app minimum size")
    func lockedLoginResizeResultDoesNotUpdateMinimumSize() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService(sessionStore: store)
        let sessionID = store.createSession(
            streamID: 141,
            mediaStreamID: 141,
            window: MirageWindow(
                id: 0,
                title: "Sign In",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1366, height: 1024),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            minSize: nil
        )
        let result = appResizeResult(
            streamID: 141,
            mediaStreamID: 141,
            windowID: 0,
            outcome: .noChange,
            requestedSize: CGSize(width: 1600, height: 1200),
            observedSize: CGSize(width: 1366, height: 1024),
            minSize: CGSize(width: 1366, height: 1024),
            reason: "lockedLoginFixedSurface"
        )

        service.handleAppWindowResizeResult(try ControlMessage(type: .appWindowResizeResult, content: result))

        #expect(service.appWindowResizeResultByStreamID[141] == result)
        #expect(store.sessionMinSizes[sessionID] == nil)
        #expect(store.sessionMinSizeUpdateGenerations[sessionID] == nil)
        #expect(store.session(for: sessionID)?.minWidth == 400)
        #expect(store.session(for: sessionID)?.minHeight == 300)
    }

    @MainActor
    @Test("App stream-start minimum size does not constrain app session")
    func appStreamStartMinimumSizeDoesNotConstrainAppSession() async throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService(sessionStore: store)
        let sessionID = store.createSession(
            streamID: 151,
            mediaStreamID: 151,
            window: MirageWindow(
                id: 15101,
                title: "Logical App Window",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            minSize: nil
        )
        let started = StreamStartedMessage(
            streamID: 151,
            windowID: 15101,
            width: 1280,
            height: 960,
            frameRate: 60,
            codec: .h264,
            minWidth: 1280,
            minHeight: 960,
            dimensionToken: 2,
            acceptedMediaMaxPacketSize: nil
        )

        await service.handleStreamStarted(try ControlMessage(type: .streamStarted, content: started))

        #expect(store.sessionMinSizes[sessionID] == nil)
        #expect(store.sessionMinSizeUpdateGenerations[sessionID] == nil)
        #expect(store.session(for: sessionID)?.minWidth == 400)
        #expect(store.session(for: sessionID)?.minHeight == 300)
    }

    @MainActor
    @Test("App resize ack ignores stale stream-start echoes")
    func ignoresStaleStreamStartEchoes() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let stale = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )

        #expect(!isMeaningfulAppResizeAcknowledgement(stale, comparedTo: baseline))
    }

    @MainActor
    @Test("App resize ack accepts dimension-token advances")
    func acceptsDimensionTokenAdvance() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let advanced = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 8
        )

        #expect(isMeaningfulAppResizeAcknowledgement(advanced, comparedTo: baseline))
    }

    @MainActor
    @Test("App resize stream-start handling rechecks minimum size after encoded dimensions change")
    func rechecksMinimumSizeAfterEncodedDimensionsChange() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let acknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 2720,
            height: 1530,
            dimensionToken: 8
        )

        #expect(isMeaningfulAppResizeAcknowledgement(acknowledgement, comparedTo: baseline))
    }

    private func appResizeResult(
        streamID: StreamID,
        mediaStreamID: StreamID,
        windowID: WindowID,
        outcome: MirageAppWindowResizeResultOutcome,
        requestedSize: CGSize,
        observedSize: CGSize,
        minSize: CGSize?,
        reason: String?
    ) -> AppWindowResizeResultMessage {
        AppWindowResizeResultMessage(
            streamID: streamID,
            mediaStreamID: mediaStreamID,
            windowID: windowID,
            outcome: outcome,
            requestedWidth: Int(requestedSize.width),
            requestedHeight: Int(requestedSize.height),
            observedWidth: Int(observedSize.width),
            observedHeight: Int(observedSize.height),
            minWidth: minSize.map { Int($0.width) },
            minHeight: minSize.map { Int($0.height) },
            reason: reason
        )
    }
}
