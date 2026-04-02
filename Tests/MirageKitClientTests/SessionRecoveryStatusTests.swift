//
//  SessionRecoveryStatusTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Session recovery-status propagation for client stream UI.
//

@testable import MirageKitClient
import CoreGraphics
import MirageKit
import Testing

@Suite("Session Recovery Status")
struct SessionRecoveryStatusTests {
    @Test("Pending recovery status is applied when the session appears")
    @MainActor
    func pendingRecoveryStatusAppliesOnSessionCreation() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 41

        store.setClientRecoveryStatus(for: streamID, status: .startup)

        let sessionID = store.createSession(
            streamID: streamID,
            window: testWindow(id: 4101),
            hostName: "Host",
            minSize: nil
        )

        #expect(store.session(for: sessionID)?.clientRecoveryStatus == .startup)
    }

    @Test("Active session recovery status updates in place")
    @MainActor
    func activeSessionRecoveryStatusUpdatesInPlace() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 42
        let sessionID = store.createSession(
            streamID: streamID,
            window: testWindow(id: 4201),
            hostName: "Host",
            minSize: nil
        )

        store.setClientRecoveryStatus(for: streamID, status: .hardRecovery)

        #expect(store.session(for: sessionID)?.clientRecoveryStatus == .hardRecovery)
    }

    @Test("Removed session does not retain stale recovery status")
    @MainActor
    func removedSessionDoesNotRetainStaleRecoveryStatus() {
        let store = MirageClientSessionStore()
        let streamID: StreamID = 43
        let firstSessionID = store.createSession(
            streamID: streamID,
            window: testWindow(id: 4301),
            hostName: "Host",
            minSize: nil
        )

        store.setClientRecoveryStatus(for: streamID, status: .keyframeRecovery)
        #expect(store.session(for: firstSessionID)?.clientRecoveryStatus == .keyframeRecovery)

        store.removeSession(firstSessionID)

        let secondSessionID = store.createSession(
            streamID: streamID,
            window: testWindow(id: 4302),
            hostName: "Host",
            minSize: nil
        )

        #expect(store.session(for: secondSessionID)?.clientRecoveryStatus == .idle)
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
