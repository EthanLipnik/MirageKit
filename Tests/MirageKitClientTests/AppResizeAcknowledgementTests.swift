//
//  AppResizeAcknowledgementTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/27/26.
//

@testable import MirageKitClient
import Testing
import CoreGraphics
import MirageKit

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
            window: MirageWindow(
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
            window: MirageWindow(
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
}
