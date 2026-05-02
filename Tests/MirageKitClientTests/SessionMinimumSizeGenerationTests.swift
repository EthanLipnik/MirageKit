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
        store.createSession(
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
        store.createSession(
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

    @Test("First-frame readiness can reset for a fresh presentation lifecycle")
    @MainActor
    func firstFrameReadinessResetsForFreshPresentationLifecycle() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 22
        store.createSession(
            streamID: streamID,
            window: testWindow(id: 2201),
            hostName: "Host",
            minSize: nil
        )

        store.markFirstFramePresented(for: streamID)
        #expect(store.sessionByStreamID(streamID)?.hasDecodedFrame == true)
        #expect(store.sessionByStreamID(streamID)?.hasPresentedFrame == true)

        store.resetFirstFrameReadiness(for: streamID)
        #expect(store.sessionByStreamID(streamID)?.hasDecodedFrame == false)
        #expect(store.sessionByStreamID(streamID)?.hasPresentedFrame == false)
    }

    @Test("Host policies determine presentation tiers")
    @MainActor
    func hostPoliciesDeterminePresentationTier() {
        let store = MirageClientSessionStore()
        let firstSessionID = store.createSession(
            streamID: 31,
            window: testWindow(id: 3101),
            hostName: "Host",
            minSize: nil
        )
        store.createSession(
            streamID: 32,
            window: testWindow(id: 3201),
            hostName: "Host",
            minSize: nil
        )

        store.applyHostStreamPolicies([
            MirageStreamPolicy(
                streamID: 31,
                tier: .activeLive,
                targetFPS: 60,
                targetBitrateBps: 12_000_000
            ),
            MirageStreamPolicy(
                streamID: 32,
                tier: .passiveSnapshot,
                targetFPS: 1,
                targetBitrateBps: 1_000_000
            )
        ])

        store.setFocusedSession(firstSessionID)

        #expect(store.presentationTier(for: 31) == .activeLive)
        #expect(store.presentationTier(for: 32) == .passiveSnapshot)
    }

    @Test("Media-stream readiness propagates to logical sessions")
    @MainActor
    func mediaStreamReadinessPropagatesToLogicalSessions() {
        let store = MirageClientSessionStore()
        let mediaStreamID: StreamID = 50
        let firstSessionID = store.createSession(
            streamID: 51,
            mediaStreamID: mediaStreamID,
            window: testWindow(id: 5101),
            hostName: "Host",
            minSize: nil
        )
        let secondSessionID = store.createSession(
            streamID: 52,
            mediaStreamID: mediaStreamID,
            window: testWindow(id: 5201),
            hostName: "Host",
            minSize: nil
        )

        store.markFirstFrameDecoded(for: mediaStreamID)
        #expect(store.session(for: firstSessionID)?.hasDecodedFrame == true)
        #expect(store.session(for: secondSessionID)?.hasDecodedFrame == true)
        #expect(store.session(for: firstSessionID)?.hasPresentedFrame == false)

        store.markFirstFramePresented(for: mediaStreamID)
        #expect(store.session(for: firstSessionID)?.hasPresentedFrame == true)
        #expect(store.session(for: secondSessionID)?.hasPresentedFrame == true)
    }

    @Test("Media-stream recovery status propagates to logical sessions")
    @MainActor
    func mediaStreamRecoveryStatusPropagatesToLogicalSessions() {
        let store = MirageClientSessionStore()
        let mediaStreamID: StreamID = 60
        let firstSessionID = store.createSession(
            streamID: 61,
            mediaStreamID: mediaStreamID,
            window: testWindow(id: 6101),
            hostName: "Host",
            minSize: nil
        )
        let secondSessionID = store.createSession(
            streamID: 62,
            mediaStreamID: mediaStreamID,
            window: testWindow(id: 6201),
            hostName: "Host",
            minSize: nil
        )

        store.setClientRecoveryStatus(for: mediaStreamID, status: .hardRecovery)

        #expect(store.session(for: firstSessionID)?.clientRecoveryStatus == .hardRecovery)
        #expect(store.session(for: secondSessionID)?.clientRecoveryStatus == .hardRecovery)
    }

    @Test("Session presentation tier resolves through media stream")
    @MainActor
    func sessionPresentationTierResolvesThroughMediaStream() {
        let store = MirageClientSessionStore()
        let sessionID = store.createSession(
            streamID: 71,
            mediaStreamID: 70,
            window: testWindow(id: 7101),
            hostName: "Host",
            minSize: nil
        )
        store.applyHostStreamPolicies([
            MirageStreamPolicy(
                streamID: 70,
                tier: .passiveSnapshot,
                targetFPS: 1,
                targetBitrateBps: 1_000_000
            ),
        ])

        let session = store.session(for: sessionID)
        #expect(session.map { store.presentationTier(for: $0) } == .passiveSnapshot)
        #expect(store.presentationTier(for: 71) == .activeLive)
    }

    @Test("Atlas region is stored on logical session")
    @MainActor
    func atlasRegionIsStoredOnLogicalSession() {
        let store = MirageClientSessionStore()
        let initialRegion = MirageAppAtlasRegion(
            windowID: 8101,
            x: 10,
            y: 20,
            width: 640,
            height: 480
        )
        let sessionID = store.createSession(
            streamID: 81,
            mediaStreamID: 80,
            window: testWindow(id: 8101),
            hostName: "Host",
            atlasRegion: initialRegion,
            minSize: nil
        )

        #expect(store.session(for: sessionID)?.atlasRegion == initialRegion)

        let updatedRegion = MirageAppAtlasRegion(
            windowID: 8102,
            x: 100,
            y: 120,
            width: 800,
            height: 600
        )
        store.updateSessionWindowMetadata(
            streamID: 81,
            window: testWindow(id: 8102),
            atlasRegion: updatedRegion
        )

        #expect(store.session(for: sessionID)?.window.id == 8102)
        #expect(store.session(for: sessionID)?.atlasRegion == updatedRegion)
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
