//
//  MirageInterceptedShortcutPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Intercepted shortcut policy")
struct MirageInterceptedShortcutPolicyTests {
    @Test("Claimed UIKit shortcuts are classified by modifiers and key code")
    func claimedUIKitShortcutsAreClassified() throws {
        let interceptedShortcuts: [(input: String, modifiers: MirageModifierFlags, keyCode: UInt16)] = [
            ("b", [.command], 0x0B),
            ("i", [.command], 0x22),
            ("u", [.command], 0x20),
            ("q", [.command], 0x0C),
            ("w", [.command], 0x0D),
            ("w", [.command, .shift], 0x0D),
            ("z", [.command], 0x06),
            ("z", [.command, .shift], 0x06),
            ("h", [.command], 0x04),
            ("m", [.command], 0x2E),
            (",", [.command], 0x2B),
        ]

        for shortcut in interceptedShortcuts {
            let byInput = try #require(
                MirageInterceptedShortcutPolicy.shortcut(
                    input: shortcut.input,
                    modifiers: shortcut.modifiers
                )
            )
            #expect(byInput.keyCode == shortcut.keyCode)

            let byKeyCode = try #require(
                MirageInterceptedShortcutPolicy.shortcut(
                    keyCode: shortcut.keyCode,
                    modifiers: shortcut.modifiers.union(.capsLock)
                )
            )
            #expect(byKeyCode.input == shortcut.input)
        }

        #expect(
            MirageInterceptedShortcutPolicy.shortcut(
                input: "b",
                modifiers: [.command, .shift]
            ) == nil
        )
    }

    @Test("Only undo and redo allow repeat")
    func onlyUndoAndRedoAllowRepeat() throws {
        let repeatableShortcuts: [(String, MirageModifierFlags)] = [
            ("z", [.command]),
            ("z", [.command, .shift]),
        ]
        let nonRepeatableShortcuts: [(String, MirageModifierFlags)] = [
            ("b", [.command]),
            ("w", [.command]),
            ("w", [.command, .shift]),
            ("q", [.command]),
        ]

        for shortcut in repeatableShortcuts {
            let intercepted = try #require(
                MirageInterceptedShortcutPolicy.shortcut(
                    input: shortcut.0,
                    modifiers: shortcut.1
                )
            )
            #expect(intercepted.allowsRepeat)
        }

        for shortcut in nonRepeatableShortcuts {
            let intercepted = try #require(
                MirageInterceptedShortcutPolicy.shortcut(
                    input: shortcut.0,
                    modifiers: shortcut.1
                )
            )
            #expect(!intercepted.allowsRepeat)
        }
    }

    @Test("UIKit edit action names resolve to intercepted shortcuts")
    func uiKitEditActionNamesResolveToInterceptedShortcuts() throws {
        let actionMappings: [(actionName: String, input: String, modifiers: MirageModifierFlags)] = [
            ("undo:", "z", [.command]),
            ("redo:", "z", [.command, .shift]),
            ("toggleBoldface:", "b", [.command]),
            ("toggleItalics:", "i", [.command]),
            ("toggleUnderline:", "u", [.command]),
        ]

        for mapping in actionMappings {
            let shortcut = try #require(
                MirageInterceptedShortcutPolicy.shortcut(actionName: mapping.actionName)
            )
            #expect(shortcut.input == mapping.input)
            #expect(shortcut.modifiers == mapping.modifiers)
        }

        #expect(
            MirageInterceptedShortcutPolicy.shortcut(actionName: "copy:") == nil
        )
    }

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
