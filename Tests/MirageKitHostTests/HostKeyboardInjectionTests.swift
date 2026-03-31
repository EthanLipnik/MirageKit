//
//  HostKeyboardInjectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

#if os(macOS)
import CoreGraphics
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host keyboard injection")
struct HostKeyboardInjectionTests {
    @Test("Physical A key stays on the virtual-key injection path")
    func physicalAKeyStaysOnVirtualKeyInjectionPath() throws {
        let event = MirageKeyEvent(
            keyCode: 0x00,
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifiers: [.command]
        )

        let plan = MirageHostInputController.keyboardInjectionPlan(for: event)
        #expect(plan.virtualKey == CGKeyCode(0))
        #expect(plan.unicodeString == nil)

        let controller = MirageHostInputController()
        let cgEvent = try #require(controller.makeInjectedKeyboardEvent(isKeyDown: true, event))
        #expect(cgEvent.getIntegerValueField(.keyboardEventKeycode) == 0)
    }

    @Test("Unicode fallback sentinel injects the provided string")
    func unicodeFallbackSentinelInjectsTheProvidedString() throws {
        let event = MirageKeyEvent(
            keyCode: MirageKeyEvent.unicodeScalarFallbackKeyCode,
            characters: "🙂",
            charactersIgnoringModifiers: "🙂"
        )

        let plan = MirageHostInputController.keyboardInjectionPlan(for: event)
        #expect(plan.virtualKey == CGKeyCode(0))
        #expect(plan.unicodeString == "🙂")

        let controller = MirageHostInputController()
        let cgEvent = try #require(controller.makeInjectedKeyboardEvent(isKeyDown: true, event))
        #expect(unicodeString(from: cgEvent) == "🙂")
    }

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var buffer = Array<UniChar>(repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        return String(utf16CodeUnits: buffer, count: length)
    }
}
#endif
