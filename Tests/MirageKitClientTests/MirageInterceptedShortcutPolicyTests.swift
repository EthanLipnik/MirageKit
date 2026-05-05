//
//  MirageInterceptedShortcutPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Intercepted Shortcut Policy")
struct MirageInterceptedShortcutPolicyTests {

    @Test("Cmd+B builds a forwarded key down and key up sequence")
    func cmdBBuildsAForwardedKeySequence() throws {
        let shortcut = try #require(
            MirageInterceptedShortcutPolicy.shortcut(
                input: "b",
                modifiers: [.command]
            )
        )

        let keyDown = shortcut.keyDownEvent(baseModifiers: [])
        let keyUp = shortcut.keyUpEvent(baseModifiers: [])

        #expect(keyDown.keyCode == 0x0B)
        #expect(keyDown.characters == "b")
        #expect(keyDown.charactersIgnoringModifiers == "b")
        #expect(keyDown.modifiers == [.command])
        #expect(!keyDown.isRepeat)

        #expect(keyUp.keyCode == 0x0B)
        #expect(keyUp.characters == "b")
        #expect(keyUp.charactersIgnoringModifiers == "b")
        #expect(keyUp.modifiers == [.command])
    }
}
