//
//  MirageInputTests.swift
//  MirageInput
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageInput
import Testing

@Suite("MirageInput")
struct MirageInputTests {
    @Test("Shortcut bindings normalize state-only modifiers")
    func shortcutBindingsNormalizeStateOnlyModifiers() {
        let binding = MirageInput.MirageClientShortcutBinding(
            keyCode: 0x23,
            modifiers: [.control, .option, .shift]
        )
        let event = MirageInput.MirageKeyEvent(
            keyCode: 0x23,
            modifiers: [.control, .option, .shift, .capsLock, .numericPad, .function]
        )

        #expect(binding.matches(event))
        #expect(binding.displayString.hasSuffix("P"))
        #expect(MirageInput.MirageClientShortcutBinding.keyName(for: 0x23) == "P")
        #expect(MirageInput.MirageClientShortcutBinding.keyName(for: 0x60) == "Key 96")
    }

    @Test("Input events round trip pointer metadata")
    func inputEventsRoundTripPointerMetadata() throws {
        let stylus = MirageInput.MirageStylusEvent(
            altitudeAngle: 1.0,
            azimuthAngle: 2.0,
            tiltX: -0.25,
            tiltY: 0.5,
            rollAngle: 0.75,
            zOffset: 0.2,
            isHovering: true
        )
        let event = MirageInput.MirageInputEvent.mouseDragged(
            MirageInput.MirageMouseEvent(
                button: .button3,
                location: CGPoint(x: 0.25, y: 1.25),
                clickCount: 2,
                modifiers: [.control, .function],
                pressure: 0.4,
                stylus: stylus,
                timestamp: 12.5
            )
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(MirageInput.MirageInputEvent.self, from: data)

        guard case let .mouseDragged(mouseEvent) = decoded else {
            Issue.record("Expected mouseDragged input event")
            return
        }

        #expect(mouseEvent.button == .button3)
        #expect(mouseEvent.location == CGPoint(x: 0.25, y: 1.25))
        #expect(mouseEvent.clickCount == 2)
        #expect(mouseEvent.modifiers == [.control, .function])
        #expect(mouseEvent.pressure == 0.4)
        #expect(mouseEvent.stylus == stylus)
        #expect(mouseEvent.timestamp == 12.5)
    }

    @Test("Resize events preserve pixel contracts")
    func resizeEventsPreservePixelContracts() {
        let resize = MirageInput.MirageResizeEvent(
            windowID: 7,
            newSize: CGSize(width: 640, height: 360),
            scaleFactor: 2.0,
            timestamp: 1
        )
        let tooSmall = MirageInput.MirageRelativeResizeEvent(
            windowID: 8,
            aspectRatio: 16.0 / 9.0,
            relativeScale: 0.001,
            clientScreenSize: CGSize(width: 1024, height: 768),
            pixelWidth: 1280,
            pixelHeight: 720,
            timestamp: 2
        )
        let tooLarge = MirageInput.MirageRelativeResizeEvent(
            windowID: 9,
            aspectRatio: 16.0 / 9.0,
            relativeScale: 2.0,
            clientScreenSize: CGSize(width: 1024, height: 768),
            timestamp: 3
        )
        let pixel = MirageInput.MiragePixelResizeEvent(
            windowID: 10,
            pixelWidth: 1920,
            pixelHeight: 1080,
            timestamp: 4
        )

        #expect(resize.pixelSize == CGSize(width: 1280, height: 720))
        #expect(tooSmall.relativeScale == 0.01)
        #expect(tooSmall.pixelWidth == 1280)
        #expect(tooSmall.pixelHeight == 720)
        #expect(tooLarge.relativeScale == 1.0)
        #expect(pixel.pixelWidth == 1920)
        #expect(pixel.pixelHeight == 1080)
    }

    @Test("Built-in actions expose host system action requests")
    func builtInActionsExposeHostSystemActionRequests() throws {
        let request = try #require(MirageInput.MirageAction.spaceLeft.hostSystemActionRequest)

        #expect(request.action == .spaceLeft)
        #expect(request.fallbackKeyEvent == MirageInput.MirageAction.spaceLeft.hostKeyEvent)
        #expect(MirageInput.MirageAction.cmdTab.hostSystemActionRequest == nil)
    }
}
