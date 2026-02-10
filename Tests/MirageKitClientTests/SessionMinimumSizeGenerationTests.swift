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
