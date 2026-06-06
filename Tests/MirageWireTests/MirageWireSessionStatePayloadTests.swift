//
//  MirageWireSessionStatePayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageWire
import Testing

@Suite("MirageWire Session State Payloads")
struct MirageWireSessionStatePayloadTests {
    @Test("Host session availability keeps stable wire names")
    func hostSessionAvailabilityKeepsStableWireNames() {
        #expect(MirageWire.MirageHostSessionAvailability.ready.rawValue == "ready")
        #expect(MirageWire.MirageHostSessionAvailability.credentialsRequired.rawValue == "credentialsRequired")
        #expect(
            MirageWire.MirageHostSessionAvailability.credentialsAndUserIdentifierRequired.rawValue
                == "credentialsAndUserIdentifierRequired"
        )
        #expect(MirageWire.MirageHostSessionAvailability.unavailable.rawValue == "unavailable")
        #expect(MirageWire.MirageHostSessionAvailability.ready.isReady)
        #expect(!MirageWire.MirageHostSessionAvailability.ready.requiresCredentials)
        #expect(MirageWire.MirageHostSessionAvailability.credentialsRequired.requiresCredentials)
        #expect(!MirageWire.MirageHostSessionAvailability.credentialsRequired.requiresUserIdentifier)
        #expect(MirageWire.MirageHostSessionAvailability.credentialsAndUserIdentifierRequired.requiresUserIdentifier)
    }

    @Test("Session state update payload round-trips in wire target")
    func sessionStateUpdatePayloadRoundTripsInWireTarget() throws {
        let update = MirageWire.SessionStateUpdateMessage(
            state: .credentialsAndUserIdentifierRequired,
            sessionToken: "session-token",
            requiresUserIdentifier: true
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .sessionStateUpdate, content: update).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.SessionStateUpdateMessage.self)

        #expect(decoded.state == .credentialsAndUserIdentifierRequired)
        #expect(decoded.state.requiresCredentials)
        #expect(decoded.state.requiresUserIdentifier)
        #expect(decoded.sessionToken == "session-token")
        #expect(decoded.requiresUserIdentifier)
    }
}
