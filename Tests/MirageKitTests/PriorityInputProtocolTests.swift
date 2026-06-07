//
//  PriorityInputProtocolTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

@testable import MirageKit
import Foundation
import Testing
import MirageWire

@Suite("Priority Input Protocol")
struct PriorityInputProtocolTests {
    @Test("Priority input envelope round-trips binary payload")
    func priorityInputEnvelopeRoundTripsBinaryPayload() throws {
        let envelope = MirageWire.MiragePriorityInputEnvelope(
            kind: .input,
            eventID: 42,
            streamID: 7,
            deliveryClass: .protected,
            sentAtUptime: 123.456,
            inputPayload: Data([0x00, 0xFE, 0x7A])
        )

        let decoded = try MirageWire.MiragePriorityInputEnvelope.deserialize(envelope.serialize())

        #expect(decoded == envelope)
        #expect(try decoded.inputControlMessage().type == .inputEvent)
        #expect(try decoded.inputControlMessage().payload == Data([0x00, 0xFE, 0x7A]))
    }

    @Test("Priority input fallback control type parses")
    func priorityInputFallbackControlTypeParses() throws {
        let envelope = MirageWire.MiragePriorityInputEnvelope(
            kind: .ack,
            eventID: 9,
            streamID: 0,
            deliveryClass: .realtime,
            sentAtUptime: 1
        )
        let controlMessage = MirageWire.ControlMessage(
            type: .priorityInputEvent,
            payload: try envelope.serialize()
        )

        switch MirageWire.ControlMessage.deserialize(from: controlMessage.serialize()) {
        case let .success(message, consumed):
            #expect(consumed == controlMessage.serialize().count)
            #expect(message.type == .priorityInputEvent)
            #expect(try MirageWire.MiragePriorityInputEnvelope.deserialize(message.payload) == envelope)
        default:
            Issue.record("Expected priority input control message to parse.")
        }
    }
}
