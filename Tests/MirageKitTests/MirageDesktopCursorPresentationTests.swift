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
    @Test("Cursor source raw values match UI labels")
    func cursorSourceRawValuesMatchUILabels() {
        #expect(MirageDesktopCursorSource.client.rawValue == "client")
        #expect(MirageDesktopCursorSource.simulated.rawValue == "simulated")
        #expect(MirageDesktopCursorSource.host.rawValue == "host")
    }

    @Test("Client cursor uses local presentation without host capture")
    func clientCursorUsesLocalPresentation() {
        let presentation = MirageDesktopCursorPresentation(
            source: .client,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.capturesHostCursor == false)
        #expect(presentation.hidesLocalCursor == false)
        #expect(presentation.rendersSyntheticClientCursor == false)
        #expect(presentation.requiresCursorPositionUpdates)
    }

    @Test("Simulated cursor hides the local cursor without host capture")
    func simulatedCursorHidesLocalCursor() {
        let presentation = MirageDesktopCursorPresentation(
            source: .simulated,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.hidesLocalCursor)
        #expect(presentation.capturesHostCursor == false)
    }

    @Test("Simulated cursor stays unlocked for mirrored desktop")
    func simulatedCursorMirroredDesktopDoesNotLock() {
        let presentation = MirageDesktopCursorPresentation(
            source: .simulated,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified) == false)
    }

    @Test("Simulated cursor honors mirrored desktop lock preference")
    func simulatedCursorMirroredDesktopHonorsLockPreference() {
        let presentation = MirageDesktopCursorPresentation(
            source: .simulated,
            lockClientCursorWhenUsingMirageCursor: true,
            lockClientCursorWhenUsingHostCursor: true
        )

        #expect(presentation.locksClientCursor(for: .unified))
    }

    @Test("Simulated cursor always locks for secondary desktop")
    func simulatedCursorSecondaryDesktopLocks() {
        let presentation = MirageDesktopCursorPresentation(
            source: .simulated,
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

        #expect(presentation.hidesLocalCursor)
        #expect(presentation.locksClientCursor(for: .unified))
    }

    @Test("Host cursor honors lock toggle when disabled")
    func hostCursorWithLockDisabledLeavesClientCursorUnlocked() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: true,
            lockClientCursorWhenUsingHostCursor: false
        )

        #expect(presentation.hidesLocalCursor)
        #expect(presentation.locksClientCursor(for: .secondary) == false)
    }
}
