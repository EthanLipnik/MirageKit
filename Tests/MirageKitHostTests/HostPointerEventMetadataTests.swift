//
//  HostPointerEventMetadataTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

#if os(macOS)
import CoreGraphics
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host pointer event metadata")
struct HostPointerEventMetadataTests {
    @Test("Pointer events carry click count and modifier flags")
    func pointerEventsCarryClickCountAndModifierFlags() {
        let controller = MirageHostInputController()
        let event = MirageMouseEvent(
            button: .right,
            location: .zero,
            clickCount: 2,
            modifiers: [.command, .shift]
        )

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .right
        ) else {
            Issue.record("Failed to create pointer CGEvent")
            return
        }

        controller.applyPointerEventMetadata(cgEvent, from: event, type: .rightMouseDown)

        #expect(cgEvent.flags.contains(.maskCommand))
        #expect(cgEvent.flags.contains(.maskShift))
        #expect(!cgEvent.flags.contains(.maskControl))
        #expect(cgEvent.getIntegerValueField(.mouseEventClickState) == 2)
    }
}
#endif
