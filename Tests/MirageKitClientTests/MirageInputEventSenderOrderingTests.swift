//
//  MirageInputEventSenderOrderingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Input Sender Ordering")
struct MirageInputEventSenderOrderingTests {
    @Test("Discrete best-effort sends preserve input order")
    func discreteBestEffortSendsPreserveInputOrder() async throws {
        let sender = MirageInputEventSender()
        let recorder = EventOrderRecorder()
        let streamID: StreamID = 905
        let keyEvent = MirageKeyEvent(keyCode: 0x7E, modifiers: .control)

        sender.updateSendHandler { data, _ in
            guard case let .success(message, _) = ControlMessage.deserialize(from: data) else {
                Issue.record("Expected a serialized control message")
                return
            }

            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            if case .flagsChanged = inputMessage.event {
                try await Task.sleep(for: .milliseconds(40))
            }

            await recorder.append(Self.label(for: inputMessage.event))
        }

        sender.sendInputFireAndForget(.flagsChanged([.control]), streamID: streamID)
        sender.sendInputFireAndForget(.keyDown(keyEvent), streamID: streamID)
        sender.sendInputFireAndForget(.keyUp(keyEvent), streamID: streamID)

        try await Task.sleep(for: .milliseconds(200))

        #expect(await recorder.snapshot() == ["flagsChanged", "keyDown", "keyUp"])
    }

    private static func label(for event: MirageInputEvent) -> String {
        switch event {
        case .flagsChanged:
            "flagsChanged"
        case .keyDown:
            "keyDown"
        case .keyUp:
            "keyUp"
        default:
            "other"
        }
    }
}

private actor EventOrderRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}
#endif
