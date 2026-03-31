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
}
