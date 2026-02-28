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

        store.markFirstFramePresented(for: streamID)
        #expect(!store.isAwaitingPostResizeFirstFrame(for: streamID))
        #expect(store.sessionByStreamID(streamID)?.hasPresentedFrame == true)
    }

    @Test("Decoded and presented readiness are tracked independently")
    @MainActor
    func decodedAndPresentedReadinessAreTrackedIndependently() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 21
        _ = store.createSession(
            streamID: streamID,
            window: testWindow(id: 2101),
            hostName: "Host",
            minSize: nil
        )

        store.markFirstFrameDecoded(for: streamID)
        #expect(store.sessionByStreamID(streamID)?.hasDecodedFrame == true)
        #expect(store.sessionByStreamID(streamID)?.hasPresentedFrame == false)

        store.markFirstFramePresented(for: streamID)
        #expect(store.sessionByStreamID(streamID)?.hasDecodedFrame == true)
        #expect(store.sessionByStreamID(streamID)?.hasPresentedFrame == true)
    }

    @Test("Focused stream resolves to active tier while others become passive")
    @MainActor
    func focusedStreamResolvesToActiveTier() async throws {
        let store = MirageClientSessionStore()
        let firstSessionID = store.createSession(
            streamID: 31,
            window: testWindow(id: 3101),
            hostName: "Host",
            minSize: nil
        )
        _ = store.createSession(
            streamID: 32,
            window: testWindow(id: 3201),
            hostName: "Host",
            minSize: nil
        )

        store.setFocusedSession(firstSessionID)

        try await Task.sleep(for: .milliseconds(80))
        #expect(store.presentationTier(for: 31) == .activeLive)
        #expect(store.presentationTier(for: 32) == .passiveSnapshot)
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
