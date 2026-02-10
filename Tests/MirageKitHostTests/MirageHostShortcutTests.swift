//
//  MirageHostShortcutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Host shortcut matching and display formatting coverage.
//

import MirageKit
import MirageKitHost
import Testing

@Suite("MirageHostShortcut")
struct MirageHostShortcutTests {
    @Test
    func shortcutMatchingNormalizesModifiers() {
        let shortcut = MirageHostShortcut(keyCode: 0x35, modifiers: [.command, .control, .option])
        #expect(shortcut.matches(keyCode: 0x35, modifiers: [.command, .control, .option, .capsLock]))
    }

    @Test
    func shortcutMatchingRejectsDifferentKeyCode() {
        let shortcut = MirageHostShortcut.defaultLightsOutRecovery
        #expect(!shortcut.matches(keyCode: 0x00, modifiers: shortcut.modifiers))
    }

    @Test
    func displayStringIncludesModifiersAndKey() {
        let shortcut = MirageHostShortcut.defaultLightsOutRecovery
        #expect(shortcut.displayString.contains("⌃"))
        #expect(shortcut.displayString.contains("⌥"))
        #expect(shortcut.displayString.contains("⌘"))
        #expect(shortcut.displayString.contains("⎋"))
    }
}
