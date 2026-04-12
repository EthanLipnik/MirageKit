//
//  HostSystemActionSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

@testable import MirageKit
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

    @Test("Built-in navigation actions map to host system actions")
    func builtInNavigationActionsMapToHostSystemActions() {
        #expect(MirageAction.spaceLeft.hostSystemActionRequest?.action == .spaceLeft)
        #expect(MirageAction.spaceRight.hostSystemActionRequest?.action == .spaceRight)
        #expect(MirageAction.missionControl.hostSystemActionRequest?.action == .missionControl)
        #expect(MirageAction.appExpose.hostSystemActionRequest?.action == .appExpose)
        #expect(MirageAction.cmdTab.hostSystemActionRequest == nil)
    }
}
