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
