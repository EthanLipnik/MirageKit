//
//  MirageClientKeyEventBuilderTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Client key event builder")
struct MirageClientKeyEventBuilderTests {
    @Test("Unmapped software keyboard characters use the Unicode fallback sentinel")
    func unmappedSoftwareKeyboardCharactersUseTheUnicodeFallbackSentinel() throws {
        let event = try #require(
            MirageClientKeyEventBuilder.softwareKeyEvent(
                for: "🙂",
                baseModifiers: [.command]
            )
        )

        #expect(event.keyCode == MirageKeyEvent.unicodeScalarFallbackKeyCode)
        #expect(event.characters == "🙂")
        #expect(event.charactersIgnoringModifiers == "🙂")
        #expect(event.modifiers == [.command])
    }

    @Test("Mapped A key keeps the macOS virtual key code")
    func mappedAKeyKeepsTheMacOSVirtualKeyCode() throws {
        let event = try #require(
            MirageClientKeyEventBuilder.softwareKeyEvent(
                for: "a",
                baseModifiers: [.command]
            )
        )

        #expect(event.keyCode == 0x00)
        #expect(event.characters == "a")
        #expect(event.charactersIgnoringModifiers == "a")
        #expect(event.modifiers == [.command])
    }

    @Test("Option-produced hardware text uses Unicode fallback")
    func optionProducedHardwareTextUsesUnicodeFallback() {
        let event = MirageClientKeyEventBuilder.hardwareKeyEvent(
            keyCode: 0x1D,
            characters: "@",
            charactersIgnoringModifiers: "0",
            modifiers: [.option]
        )

        #expect(event.keyCode == MirageKeyEvent.unicodeScalarFallbackKeyCode)
        #expect(event.characters == "@")
        #expect(event.charactersIgnoringModifiers == "0")
        #expect(event.modifiers == [.option])
    }

    @Test("UIKit special hardware keys stay on virtual-key path")
    func uiKitSpecialHardwareKeysStayOnVirtualKeyPath() {
        let specialKeys: [(keyCode: UInt16, input: String)] = [
            (0x35, "UIKeyInputEscape"),
            (0x7B, "UIKeyInputLeftArrow"),
            (0x7C, "UIKeyInputRightArrow"),
            (0x7D, "UIKeyInputDownArrow"),
            (0x7E, "UIKeyInputUpArrow"),
            (0x33, "UIKeyInputDelete"),
            (0x30, "UIKeyInputTab"),
        ]

        for specialKey in specialKeys {
            let event = MirageClientKeyEventBuilder.hardwareKeyEvent(
                keyCode: specialKey.keyCode,
                characters: specialKey.input,
                charactersIgnoringModifiers: specialKey.input,
                modifiers: []
            )

            #expect(event.keyCode == specialKey.keyCode)
            #expect(!event.usesUnicodeScalarFallback)
            #expect(event.characters == nil)
            #expect(event.charactersIgnoringModifiers == nil)
        }
    }

    @Test("Tab hardware key stays on virtual-key path")
    func tabHardwareKeyStaysOnVirtualKeyPath() {
        let event = MirageClientKeyEventBuilder.hardwareKeyEvent(
            keyCode: 0x30,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            modifiers: []
        )

        #expect(event.keyCode == 0x30)
        #expect(!event.usesUnicodeScalarFallback)
        #expect(event.characters == "\t")
        #expect(event.charactersIgnoringModifiers == "\t")
    }

    @Test("Key command special inputs map to macOS virtual key codes")
    func keyCommandSpecialInputsMapToMacVirtualKeyCodes() {
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputEscape") == 0x35)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputLeftArrow") == 0x7B)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputRightArrow") == 0x7C)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputDownArrow") == 0x7D)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputUpArrow") == 0x7E)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputDelete") == 0x33)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("UIKeyInputTab") == 0x30)
        #expect(MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode("\t") == 0x30)
    }

    @Test("Command hardware shortcuts stay on virtual-key path")
    func commandHardwareShortcutsStayOnVirtualKeyPath() {
        let event = MirageClientKeyEventBuilder.hardwareKeyEvent(
            keyCode: 0x0B,
            characters: "b",
            charactersIgnoringModifiers: "b",
            modifiers: [.command]
        )

        #expect(event.keyCode == 0x0B)
        #expect(event.characters == "b")
        #expect(event.modifiers == [.command])
    }
}
