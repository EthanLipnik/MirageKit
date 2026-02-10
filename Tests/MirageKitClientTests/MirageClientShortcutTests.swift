//
//  MirageClientShortcutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Client shortcut matching and display formatting coverage.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Client Shortcut")
struct MirageClientShortcutTests {
    @Test("Shortcut matching ignores unrelated modifier bits")
    func shortcutMatchingNormalizesModifiers() {
        let shortcut = MirageClientShortcut(keyCode: 0x02, modifiers: [.command, .shift])
        let event = MirageKeyEvent(
            keyCode: 0x02,
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [.command, .shift, .capsLock]
        )

        #expect(shortcut.matches(event))
    }

    @Test("Shortcut matching rejects different key code")
    func shortcutMatchingRejectsDifferentKeyCode() {
        let shortcut = MirageClientShortcut.defaultDesktopExit
        let event = MirageKeyEvent(
            keyCode: 0x24,
            characters: "\n",
            charactersIgnoringModifiers: "\n",
            modifiers: [.control, .option]
        )

        #expect(!shortcut.matches(event))
    }

    @Test("Display string includes modifiers and key glyph")
    func displayStringIncludesComponents() {
        let shortcut = MirageClientShortcut.defaultDictationToggle
        #expect(shortcut.displayString.contains("⌘"))
        #expect(shortcut.displayString.contains("⇧"))
        #expect(shortcut.displayString.contains("⌥"))
        #expect(shortcut.displayString.contains("D"))
    }
}
