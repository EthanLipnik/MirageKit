//
//  MirageDesktopCursorLockModeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKit
import Testing

@Suite("Desktop Cursor Lock Mode")
struct MirageDesktopCursorLockModeTests {
    @Test("On locks all desktop stream modes")
    func onLocksAllDesktopStreamModes() {
        #expect(MirageDesktopCursorLockMode.on.locksClientCursor(for: .unified))
        #expect(MirageDesktopCursorLockMode.on.locksClientCursor(for: .secondary))
    }

    @Test("Secondary only locks only secondary desktop streams")
    func secondaryOnlyLocksOnlySecondaryDesktopStreams() {
        #expect(MirageDesktopCursorLockMode.secondaryOnly.locksClientCursor(for: .secondary))
        #expect(MirageDesktopCursorLockMode.secondaryOnly.locksClientCursor(for: .unified) == false)
    }

    @Test("Off never locks desktop streams")
    func offNeverLocksDesktopStreams() {
        #expect(MirageDesktopCursorLockMode.off.locksClientCursor(for: .unified) == false)
        #expect(MirageDesktopCursorLockMode.off.locksClientCursor(for: .secondary) == false)
    }
}
