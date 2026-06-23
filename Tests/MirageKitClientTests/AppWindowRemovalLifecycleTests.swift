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

@Suite("App Window Removal Lifecycle")
struct AppWindowRemovalLifecycleTests {
    @MainActor
    @Test("Host window removal tears down removed stream controller")
    func hostWindowRemovalTearsDownRemovedStreamController() async throws {
        let service = MirageClientService(deviceName: "Window Removal Test")
        let streamID: StreamID = 1
        let appSessionID = UUID()
        let window = MirageWindow(
            id: 0,
            title: "Sign In",
            application: MirageApplication(
                id: 0,
                bundleIdentifier: "com.example.Editor",
                name: "Editor"
            ),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
            isOnScreen: true,
            windowLayer: 0
        )
        var removedCallback: WindowRemovedFromStreamMessage?

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

        let removed = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            streamID: streamID,
            windowID: 0,
            reason: .noLongerEligible
        )
        try await service.handleWindowRemovedFromStream(
            ControlMessage(type: .windowRemovedFromStream, content: removed)
        )

        #expect(removedCallback?.streamID == streamID)
        #expect(service.sessionStore.sessionByStreamID(streamID) == nil)
        #expect(service.controllersByStream[streamID] == nil)
        #expect(!service.registeredStreamIDs.contains(streamID))
        #expect(!service.activeStreamIDsForFiltering.contains(streamID))
    }

    @MainActor
    @Test("Last app-atlas logical removal tears down media controller after callback removes session")
    func lastAppAtlasLogicalRemovalTearsDownMediaControllerAfterCallbackRemovesSession() async throws {
        let service = MirageClientService(deviceName: "Atlas Removal Test")
        let mediaStreamID: StreamID = 2
        let logicalStreamID: StreamID = 10
        let appSessionID = UUID()
        let window = appWindow(id: 100, title: "Editor")

        service.sessionStore.registerSession(
            streamID: logicalStreamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: "Host",
            appSessionID: appSessionID,
            minSize: nil
        )
        service.controllersByStream[mediaStreamID] = StreamController(
            streamID: mediaStreamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(mediaStreamID)
        service.fastPathState.addActiveStreamID(mediaStreamID)
        service.appAtlasLayoutsByMediaStreamID[mediaStreamID] = [:]
        service.onWindowRemovedFromStream = { [sessionStore = service.sessionStore] message in
            guard let streamID = message.streamID,
                  let session = sessionStore.sessionByStreamID(streamID) else {
                return
            }
            sessionStore.removeSession(session.id)
        }

        let removed = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            streamID: logicalStreamID,
            windowID: 100,
            reason: .noLongerEligible
        )
        try await service.handleWindowRemovedFromStream(
            ControlMessage(type: .windowRemovedFromStream, content: removed)
        )

        #expect(service.sessionStore.sessionByStreamID(logicalStreamID) == nil)
        #expect(service.controllersByStream[mediaStreamID] == nil)
        #expect(!service.registeredStreamIDs.contains(mediaStreamID))
        #expect(!service.activeStreamIDsForFiltering.contains(mediaStreamID))
        #expect(service.appAtlasLayoutsByMediaStreamID[mediaStreamID] == nil)
    }

    @MainActor
    @Test("Shared app-atlas media stays active until final logical removal")
    func sharedAppAtlasMediaStaysActiveUntilFinalLogicalRemoval() async throws {
        let service = MirageClientService(deviceName: "Shared Atlas Removal Test")
        let mediaStreamID: StreamID = 3
        let firstLogicalStreamID: StreamID = 11
        let secondLogicalStreamID: StreamID = 12
        let appSessionID = UUID()

        service.sessionStore.registerSession(
            streamID: firstLogicalStreamID,
            mediaStreamID: mediaStreamID,
            window: appWindow(id: 101, title: "Editor A"),
            hostName: "Host",
            appSessionID: appSessionID,
            minSize: nil
        )
        service.sessionStore.registerSession(
            streamID: secondLogicalStreamID,
            mediaStreamID: mediaStreamID,
            window: appWindow(id: 102, title: "Editor B"),
            hostName: "Host",
            appSessionID: appSessionID,
            minSize: nil
        )
        service.controllersByStream[mediaStreamID] = StreamController(
            streamID: mediaStreamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(mediaStreamID)
        service.fastPathState.addActiveStreamID(mediaStreamID)
        service.streamingAppBundleID = "com.example.Editor"
        service.appWindowInventory = appWindowInventory(appSessionID: appSessionID)
        service.onWindowRemovedFromStream = { [sessionStore = service.sessionStore] message in
            guard let streamID = message.streamID,
                  let session = sessionStore.sessionByStreamID(streamID) else {
                return
            }
            sessionStore.removeSession(session.id)
        }

        let firstRemoved = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            streamID: firstLogicalStreamID,
            windowID: 101,
            reason: .noLongerEligible
        )
        try await service.handleWindowRemovedFromStream(
            ControlMessage(type: .windowRemovedFromStream, content: firstRemoved)
        )

        #expect(service.sessionStore.sessionByStreamID(firstLogicalStreamID) == nil)
        #expect(service.sessionStore.sessionByStreamID(secondLogicalStreamID) != nil)
        #expect(service.controllersByStream[mediaStreamID] != nil)
        #expect(service.registeredStreamIDs.contains(mediaStreamID))
        #expect(service.activeStreamIDsForFiltering.contains(mediaStreamID))
        #expect(service.streamingAppBundleID == "com.example.Editor")
        #expect(service.appWindowInventory != nil)

        let secondRemoved = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            streamID: secondLogicalStreamID,
            windowID: 102,
            reason: .noLongerEligible
        )
        try await service.handleWindowRemovedFromStream(
            ControlMessage(type: .windowRemovedFromStream, content: secondRemoved)
        )

        #expect(service.sessionStore.sessionByStreamID(secondLogicalStreamID) == nil)
        #expect(service.controllersByStream[mediaStreamID] == nil)
        #expect(!service.registeredStreamIDs.contains(mediaStreamID))
        #expect(!service.activeStreamIDsForFiltering.contains(mediaStreamID))
        #expect(service.streamingAppBundleID == nil)
        #expect(service.appWindowInventory == nil)
    }

    @MainActor
    @Test("No-stream keyframe ack tears down unreferenced stale media controller")
    func noStreamKeyframeAckTearsDownUnreferencedStaleMediaController() async throws {
        let service = MirageClientService(deviceName: "No Stream Ack Test")
        let mediaStreamID: StreamID = 4
        service.controllersByStream[mediaStreamID] = StreamController(
            streamID: mediaStreamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(mediaStreamID)
        service.fastPathState.addActiveStreamID(mediaStreamID)

        let ack = KeyframeRecoveryAckMessage(
            streamID: mediaStreamID,
            deadlineMilliseconds: 500,
            accepted: false,
            state: .noStream
        )
        service.handleKeyframeRecoveryAck(try ControlMessage(type: .keyframeRecoveryAck, content: ack))
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.controllersByStream[mediaStreamID] == nil)
        #expect(!service.registeredStreamIDs.contains(mediaStreamID))
        #expect(!service.activeStreamIDsForFiltering.contains(mediaStreamID))
    }

    @MainActor
    @Test("Client stop-viewing final app-atlas logical stream tears down media")
    func clientStopViewingFinalAppAtlasLogicalStreamTearsDownMedia() async throws {
        let service = MirageClientService(deviceName: "Client Stop Atlas Test")
        let mediaStreamID: StreamID = 5
        let logicalStreamID: StreamID = 13
        let window = appWindow(id: 103, title: "Editor")
        let session = ClientStreamSession(
            id: logicalStreamID,
            window: window,
            mediaStreamID: mediaStreamID
        )
        service.activeStreams = [session]
        service.sessionStore.registerSession(
            streamID: logicalStreamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: "Host",
            minSize: nil
        )
        service.controllersByStream[mediaStreamID] = StreamController(
            streamID: mediaStreamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(mediaStreamID)
        service.fastPathState.addActiveStreamID(mediaStreamID)
        service.activeStreamCodecs[mediaStreamID] = .hevc
        service.appAtlasLayoutsByMediaStreamID[mediaStreamID] = [:]
        service.lastKeyframeRequestTime[mediaStreamID] = CFAbsoluteTimeGetCurrent()
        service.receiverMediaFeedbackLastSendTime[mediaStreamID] = CFAbsoluteTimeGetCurrent()
        service.streamingAppBundleID = "com.example.Editor"
        service.appWindowInventory = appWindowInventory()
        service.pendingStreamSetupKind = .app
        service.pendingAppRequestedColorDepth = .pro
        service.pendingAppRequestedLatencyMode = .balanced

        await service.stopViewing(session)

        #expect(service.sessionStore.sessionByStreamID(logicalStreamID) == nil)
        #expect(service.activeStreams.isEmpty)
        #expect(service.controllersByStream[mediaStreamID] == nil)
        #expect(!service.registeredStreamIDs.contains(mediaStreamID))
        #expect(!service.activeStreamIDsForFiltering.contains(mediaStreamID))
        #expect(service.activeStreamCodecs[mediaStreamID] == nil)
        #expect(service.appAtlasLayoutsByMediaStreamID[mediaStreamID] == nil)
        #expect(service.lastKeyframeRequestTime[mediaStreamID] == nil)
        #expect(service.receiverMediaFeedbackLastSendTime[mediaStreamID] == nil)
        #expect(service.streamingAppBundleID == nil)
        #expect(service.appWindowInventory == nil)
        #expect(service.pendingStreamSetupKind == nil)
        #expect(service.pendingAppRequestedColorDepth == nil)
        #expect(service.pendingAppRequestedLatencyMode == nil)
    }

    @MainActor
    @Test("App-atlas media teardown skips live logical session")
    func appAtlasMediaTeardownSkipsLiveLogicalSession() async throws {
        let service = MirageClientService(deviceName: "Live Atlas Guard Test")
        let mediaStreamID: StreamID = 6
        let logicalStreamID: StreamID = 14
        let window = appWindow(id: 104, title: "Editor")
        service.sessionStore.registerSession(
            streamID: logicalStreamID,
            mediaStreamID: mediaStreamID,
            window: window,
            hostName: "Host",
            minSize: nil
        )
        service.controllersByStream[mediaStreamID] = StreamController(
            streamID: mediaStreamID,
            maxPayloadSize: 1200
        )
        service.registeredStreamIDs.insert(mediaStreamID)
        service.fastPathState.addActiveStreamID(mediaStreamID)
        service.appAtlasLayoutsByMediaStreamID[mediaStreamID] = [:]

        await service.forceStopAppAtlasMediaStreamLocally(mediaStreamID: mediaStreamID)

        #expect(service.sessionStore.sessionByStreamID(logicalStreamID) != nil)
        #expect(service.controllersByStream[mediaStreamID] != nil)
        #expect(service.registeredStreamIDs.contains(mediaStreamID))
        #expect(service.activeStreamIDsForFiltering.contains(mediaStreamID))
        #expect(service.appAtlasLayoutsByMediaStreamID[mediaStreamID] != nil)

        if let controller = service.controllersByStream[mediaStreamID] {
            await controller.stop()
        }
    }

    private func appWindow(id: WindowID, title: String) -> MirageWindow {
        MirageWindow(
            id: id,
            title: title,
            application: MirageApplication(
                id: 0,
                bundleIdentifier: "com.example.Editor",
                name: "Editor"
            ),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1200),
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private func appWindowInventory(appSessionID: UUID? = nil) -> AppWindowInventoryMessage {
        AppWindowInventoryMessage(
            bundleIdentifier: "com.example.Editor",
            appSessionID: appSessionID,
            maxVisibleSlots: 1,
            slots: [],
            hiddenWindows: [
                AppWindowInventoryMessage.WindowMetadata(
                    windowID: 900,
                    title: "Editor",
                    width: 1600,
                    height: 1200,
                    isResizable: true
                )
            ]
        )
    }
}
