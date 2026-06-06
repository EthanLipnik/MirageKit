//
//  AppWindowRemovalLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing
import MirageCore
import MirageMedia
import MirageWire

@Suite("App Window Removal Lifecycle")
struct AppWindowRemovalLifecycleTests {
    @MainActor
    @Test("Host window removal tears down removed stream controller")
    func hostWindowRemovalTearsDownRemovedStreamController() async throws {
        let service = MirageClientService(deviceName: "Window Removal Test")
        let streamID: StreamID = 1
        let appSessionID = UUID()
        let window = MirageMedia.MirageWindow(
            id: 0,
            title: "Sign In",
            application: MirageMedia.MirageApplication(
                id: 0,
                bundleIdentifier: "com.example.Editor",
                name: "Editor"
            ),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
            isOnScreen: true,
            windowLayer: 0
        )
        var removedCallback: MirageWire.WindowRemovedFromStreamMessage?

        service.sessionStore.registerSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: window,
            hostName: "Host",
            appSessionID: appSessionID,
            minSize: nil
        )
        service.controllersByStream[streamID] = StreamController(
            streamID: streamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(streamID)
        service.fastPathState.addActiveStreamID(streamID)
        service.onWindowRemovedFromStream = { removedCallback = $0 }

        let removed = MirageWire.WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            streamID: streamID,
            windowID: 0,
            reason: .noLongerEligible
        )
        try await service.handleWindowRemovedFromStream(
            MirageWire.ControlMessage(type: .windowRemovedFromStream, content: removed)
        )

        #expect(removedCallback?.streamID == streamID)
        #expect(service.sessionStore.sessionByStreamID(streamID) == nil)
        #expect(service.controllersByStream[streamID] == nil)
        #expect(!service.registeredStreamIDs.contains(streamID))
        #expect(!service.activeStreamIDsForFiltering.contains(streamID))
    }
}
