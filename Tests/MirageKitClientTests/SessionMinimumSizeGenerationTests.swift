//
//  SessionMinimumSizeGenerationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Session minimum-size generation behavior for desktop resize acknowledgements.
//

@testable import MirageKitClient
import CoreGraphics
import MirageKit
import Testing

@Suite("Session Minimum Size Generation")
struct SessionMinimumSizeGenerationTests {
    @Test("Generation increments for repeated min-size updates")
    @MainActor
    func generationIncrementsForRepeatedUpdates() {
        let store = MirageClientSessionStore()
        let sessionID = store.createSession(
            streamID: 1,
            window: testWindow(id: 101),
            hostName: "Host",
            minSize: nil
        )

        let size = CGSize(width: 3200, height: 2400)
        store.updateMinimumSize(for: 1, minSize: size)
        #expect(store.sessionMinSizes[sessionID] == size)
        #expect(store.sessionMinSizeUpdateGenerations[sessionID] == 1)

        store.updateMinimumSize(for: 1, minSize: size)
        #expect(store.sessionMinSizes[sessionID] == size)
        #expect(store.sessionMinSizeUpdateGenerations[sessionID] == 2)
    }

    @Test("Unknown stream update does not create generation")
    @MainActor
    func unknownStreamUpdateDoesNotCreateGeneration() {
        let store = MirageClientSessionStore()
        store.updateMinimumSize(for: 42, minSize: CGSize(width: 100, height: 100))
        #expect(store.sessionMinSizeUpdateGenerations.isEmpty)
        #expect(store.sessionMinSizes.isEmpty)
    }

    @Test("Session metadata updates for same stream ID rebind")
    @MainActor
    func sessionMetadataUpdatesForStreamRebind() {
        let store = MirageClientSessionStore()
        let sessionID = store.createSession(
            streamID: 7,
            window: testWindow(id: 701),
            hostName: "Host",
            minSize: nil
        )

        store.updateSessionWindowMetadata(
            streamID: 7,
            window: testWindow(id: 702)
        )

        #expect(store.session(for: sessionID)?.window.id == 702)
        #expect(store.sessionForStream(701) == nil)
        #expect(store.sessionForStream(702)?.streamID == 7)
    }

    @Test("Post-resize transition clears on first frame")
    @MainActor
    func postResizeTransitionClearsOnFirstFrame() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 11
        _ = store.createSession(
            streamID: streamID,
            window: testWindow(id: 1101),
            hostName: "Host",
            minSize: nil
        )

        store.beginPostResizeTransition(for: streamID)
        #expect(store.isAwaitingPostResizeFirstFrame(for: streamID))

        store.markFirstFrameReceived(for: streamID)
        #expect(!store.isAwaitingPostResizeFirstFrame(for: streamID))
        #expect(store.sessionByStreamID(streamID)?.hasReceivedFirstFrame == true)
    }

    @Test("Removing session clears post-resize transition state")
    @MainActor
    func removingSessionClearsPostResizeTransitionState() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 12
        let sessionID = store.createSession(
            streamID: streamID,
            window: testWindow(id: 1201),
            hostName: "Host",
            minSize: nil
        )

        store.beginPostResizeTransition(for: streamID)
        #expect(store.isAwaitingPostResizeFirstFrame(for: streamID))

        store.removeSession(sessionID)
        #expect(!store.isAwaitingPostResizeFirstFrame(for: streamID))
    }

    @MainActor
    private func testWindow(id: WindowID) -> MirageWindow {
        MirageWindow(
            id: id,
            title: "Test Window",
            application: nil,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )
    }
}
