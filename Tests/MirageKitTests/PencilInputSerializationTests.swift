//
//  PencilInputSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Serialization coverage for stylus metadata in input events.
//

@testable import MirageKit
import CoreGraphics
import Foundation
import Testing

@Suite("Pencil Input Serialization")
struct PencilInputSerializationTests {
    @Test("Mouse event with stylus payload round-trips through input message")
    func stylusRoundTrip() throws {
        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 3,
            tiltX: 0.35,
            tiltY: -0.2,
            rollAngle: 0.1,
            zOffset: 0.4,
            isHovering: false
        )
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.25, y: 0.75),
            clickCount: 1,
            modifiers: [.shift],
            pressure: 0.7,
            stylus: stylus
        )
        let input = MirageInputEvent.mouseDragged(mouseEvent)
        let envelope = InputEventMessage(streamID: 42, event: input)
        let message = try ControlMessage(type: .inputEvent, payload: envelope.serializePayload())

        let serialized = message.serialize()
        let (deserialized, _) = try requireParsedControlMessage(from: serialized)
        let decodedEnvelope = try InputEventMessage.deserializePayload(deserialized.payload)

        guard case let .mouseDragged(decodedMouseEvent) = decodedEnvelope.event else {
            Issue.record("Expected mouseDragged event")
            return
        }

        #expect(decodedMouseEvent.stylus != nil)
        #expect(abs(decodedMouseEvent.pressure - 0.7) < 0.0001)
        let decodedStylus = try #require(decodedMouseEvent.stylus)
        #expect(abs(decodedStylus.altitudeAngle - stylus.altitudeAngle) < 0.0001)
        #expect(abs(decodedStylus.azimuthAngle - stylus.azimuthAngle) < 0.0001)
        #expect(abs(decodedStylus.tiltX - stylus.tiltX) < 0.0001)
        #expect(abs(decodedStylus.tiltY - stylus.tiltY) < 0.0001)
        #expect(abs((decodedStylus.rollAngle ?? 0) - (stylus.rollAngle ?? 0)) < 0.0001)
        #expect(abs((decodedStylus.zOffset ?? 0) - (stylus.zOffset ?? 0)) < 0.0001)
        #expect(decodedStylus.isHovering == stylus.isHovering)
    }

    @Test("Mouse payload without stylus decodes with nil stylus")
    func mousePayloadWithoutStylusDecode() throws {
        let mouseEventWithoutStylus = MirageMouseEvent(
            button: .left,
            location: CGPoint(x: 0.1, y: 0.2),
            clickCount: 1,
            modifiers: [.command],
            pressure: 0.8
        )

        let data = try JSONEncoder().encode(mouseEventWithoutStylus)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(jsonObject["stylus"] == nil)

        let decoded = try JSONDecoder().decode(MirageMouseEvent.self, from: data)
        #expect(decoded.stylus == nil)
        #expect(abs(decoded.pressure - mouseEventWithoutStylus.pressure) < 0.0001)
    }

}
