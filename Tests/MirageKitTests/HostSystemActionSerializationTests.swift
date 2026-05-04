//
//  HostSystemActionSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

@testable import MirageKit
import CoreGraphics
import Testing

@Suite("Host System Action Serialization")
struct HostSystemActionSerializationTests {
    @Test("Host system action request round-trips through input message")
    func hostSystemActionRoundTrip() throws {
        let request = MirageHostSystemActionRequest(
            action: .missionControl,
            fallbackKeyEvent: MirageKeyEvent(keyCode: 0x7E, modifiers: .control)
        )
        let envelope = InputEventMessage(
            streamID: 42,
            event: .hostSystemAction(request)
        )
        let message = try ControlMessage(type: .inputEvent, payload: envelope.serializePayload())

        let serialized = message.serialize()
        let (deserialized, _) = try requireParsedControlMessage(from: serialized)
        let decodedEnvelope = try InputEventMessage.deserializePayload(deserialized.payload)

        guard case let .hostSystemAction(decodedRequest) = decodedEnvelope.event else {
            Issue.record("Expected hostSystemAction event")
            return
        }

        #expect(decodedRequest == request)
    }

    @Test("Gesture input events round-trip through input message")
    func gestureInputEventsRoundTrip() throws {
        let events: [MirageInputEvent] = [
            .magnify(MirageMagnifyEvent(
                magnification: 0.25,
                location: CGPoint(x: 0.2, y: 0.8),
                phase: .changed,
                modifiers: [.command]
            )),
            .rotate(MirageRotateEvent(
                rotation: 12,
                location: CGPoint(x: 0.4, y: 0.6),
                phase: .changed,
                modifiers: [.shift]
            )),
            .swipe(MirageSwipeEvent(
                deltaX: -1,
                deltaY: 0,
                location: CGPoint(x: 0.5, y: 0.5),
                phase: .changed,
                modifiers: [.control]
            )),
        ]

        for event in events {
            let envelope = InputEventMessage(streamID: 42, event: event)
            let message = try ControlMessage(type: .inputEvent, payload: envelope.serializePayload())

            let serialized = message.serialize()
            let (deserialized, _) = try requireParsedControlMessage(from: serialized)
            let decodedEnvelope = try InputEventMessage.deserializePayload(deserialized.payload)

            assertGestureEvent(decodedEnvelope.event, matches: event)
        }
    }

    @Test("Built-in navigation actions map to host system actions")
    func builtInNavigationActionsMapToHostSystemActions() {
        #expect(MirageAction.spaceLeft.hostSystemActionRequest?.action == .spaceLeft)
        #expect(MirageAction.spaceRight.hostSystemActionRequest?.action == .spaceRight)
        #expect(MirageAction.missionControl.hostSystemActionRequest?.action == .missionControl)
        #expect(MirageAction.appExpose.hostSystemActionRequest?.action == .appExpose)
        #expect(MirageAction.cmdTab.hostSystemActionRequest == nil)
    }
}

private func assertGestureEvent(_ actual: MirageInputEvent, matches expected: MirageInputEvent) {
    switch (actual, expected) {
    case let (.magnify(actualEvent), .magnify(expectedEvent)):
        #expect(actualEvent == expectedEvent)
    case let (.rotate(actualEvent), .rotate(expectedEvent)):
        #expect(actualEvent == expectedEvent)
    case let (.swipe(actualEvent), .swipe(expectedEvent)):
        #expect(actualEvent == expectedEvent)
    default:
        Issue.record("Expected matching gesture event")
    }
}
