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
    @Test("Client cursor uses local presentation without host capture")
    func clientCursorUsesLocalPresentation() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.capturesHostCursor == false)
        #expect(presentation.rendersSyntheticClientCursor == false)
        #expect(presentation.requiresCursorPositionUpdates)
    }

    @Test("Emulated cursor stays unlocked for mirrored desktop")
    func emulatedCursorMirroredDesktopDoesNotLock() {
        let presentation = MirageDesktopCursorPresentation(
            source: .emulated,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified) == false)
    }

    @Test("Emulated cursor honors mirrored desktop lock preference")
    func emulatedCursorMirroredDesktopHonorsLockPreference() {
        let presentation = MirageDesktopCursorPresentation(
            source: .emulated,
            lockClientCursorWhenUsingMirageCursor: true,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified))
    }

    @Test("Emulated cursor always locks for secondary desktop")
    func emulatedCursorSecondaryDesktopLocks() {
        let presentation = MirageDesktopCursorPresentation(
            source: .emulated,
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
