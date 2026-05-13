//
//  MirageClientCursorStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
//

import CoreGraphics
@testable import MirageKitClient
import Testing

@Suite("Client Cursor Stores")
struct MirageClientCursorStoreTests {
    @Test("Cursor snapshots advance only when state changes")
    func cursorSnapshotsAdvanceOnlyWhenStateChanges() {
        let store = MirageClientCursorStore()

        #expect(store.updateCursor(streamID: 7, cursorType: .arrow, isVisible: true))
        #expect(store.snapshot(for: 7)?.sequence == 1)
        #expect(!store.updateCursor(streamID: 7, cursorType: .arrow, isVisible: true))
        #expect(store.snapshot(for: 7)?.sequence == 1)
        #expect(store.updateCursor(streamID: 7, cursorType: .iBeam, isVisible: true))
        #expect(store.snapshot(for: 7)?.sequence == 2)

        store.clear(streamID: 7)
        #expect(store.snapshot(for: 7) == nil)
    }

    @Test("Cursor position snapshots advance only when state changes")
    func cursorPositionSnapshotsAdvanceOnlyWhenStateChanges() {
        let store = MirageClientCursorPositionStore()
        let firstPosition = CGPoint(x: 0.25, y: 0.75)
        let secondPosition = CGPoint(x: 0.5, y: 0.5)

        #expect(store.updatePosition(streamID: 9, position: firstPosition, isVisible: true))
        #expect(store.snapshot(for: 9)?.sequence == 1)
        #expect(!store.updatePosition(streamID: 9, position: firstPosition, isVisible: true))
        #expect(store.snapshot(for: 9)?.sequence == 1)
        #expect(store.updatePosition(streamID: 9, position: secondPosition, isVisible: true))
        #expect(store.snapshot(for: 9)?.sequence == 2)

        store.clearAll()
        #expect(store.snapshot(for: 9) == nil)
    }
}
