//
//  MirageDesktopCursorPresentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKit
import Testing

@Suite("Desktop Cursor Presentation")
struct MirageDesktopCursorPresentationTests {
    @Test("Synthetic client cursor stays unlocked for mirrored desktop")
    func syntheticCursorMirroredDesktopDoesNotLock() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .mirrored) == false)
    }

    @Test("Synthetic client cursor always locks for secondary desktop")
    func syntheticCursorSecondaryDesktopLocks() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingHostCursor: false
        )

        #expect(presentation.locksClientCursor(for: .secondary))
    }

    @Test("Host cursor honors lock toggle when enabled")
    func hostCursorWithLockEnabledLocksClientCursor() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .mirrored))
    }

    @Test("Host cursor honors lock toggle when disabled")
    func hostCursorWithLockDisabledLeavesClientCursorUnlocked() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingHostCursor: false
        )

        #expect(presentation.locksClientCursor(for: .secondary) == false)
    }
}
