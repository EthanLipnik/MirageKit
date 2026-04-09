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
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified) == false)
    }

    @Test("Synthetic client cursor honors mirrored desktop lock preference")
    func syntheticCursorMirroredDesktopHonorsLockPreference() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingMirageCursor: true,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified))
    }

    @Test("Synthetic client cursor always locks for secondary desktop")
    func syntheticCursorSecondaryDesktopLocks() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: false
        )

        #expect(presentation.locksClientCursor(for: .secondary))
    }

    @Test("Host cursor honors lock toggle when enabled")
    func hostCursorWithLockEnabledLocksClientCursor() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified))
    }

    @Test("Host cursor honors lock toggle when disabled")
    func hostCursorWithLockDisabledLeavesClientCursorUnlocked() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: true,
            lockClientCursorWhenUsingHostCursor: false
        )

        #expect(presentation.locksClientCursor(for: .secondary) == false)
    }
}
