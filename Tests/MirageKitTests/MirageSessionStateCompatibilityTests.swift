//
//  MirageSessionStateCompatibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageKit
import Testing
import MirageWire

@Suite("Mirage Session State Compatibility")
struct MirageSessionStateCompatibilityTests {
    @Test("Session state update preserves Loom availability wire compatibility")
    func sessionStateUpdatePreservesLoomAvailabilityWireCompatibility() throws {
        let update = MirageWire.SessionStateUpdateMessage(
            state: MirageWire.MirageHostSessionAvailability(loomAvailability: .credentialsAndUserIdentifierRequired),
            sessionToken: "session-token",
            requiresUserIdentifier: true
        )
        let envelope = try MirageWire.ControlMessage(
            type: .sessionStateUpdate,
            content: update
        )
        .serialize()
        let (message, _) = try requireParsedControlMessage(from: envelope)
        let decoded = try message.decode(MirageWire.SessionStateUpdateMessage.self)

        #expect(decoded.state == .credentialsAndUserIdentifierRequired)
        #expect(decoded.state.loomAvailability == .credentialsAndUserIdentifierRequired)
        #expect(decoded.sessionToken == "session-token")
        #expect(decoded.requiresUserIdentifier)
    }

    @Test("Legacy Loom session-state JSON decodes through Mirage availability")
    func legacyLoomSessionStateJSONDecodesThroughMirageAvailability() throws {
        let legacy = LegacySessionStateUpdate(
            state: .credentialsRequired,
            sessionToken: "legacy-token",
            requiresUserIdentifier: false
        )
        let encoded = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(MirageWire.SessionStateUpdateMessage.self, from: encoded)

        #expect(decoded.state == .credentialsRequired)
        #expect(decoded.state.loomAvailability == .credentialsRequired)
        #expect(decoded.sessionToken == "legacy-token")
        #expect(!decoded.requiresUserIdentifier)
    }

    private struct LegacySessionStateUpdate: Codable {
        let state: LoomSessionAvailability
        let sessionToken: String
        let requiresUserIdentifier: Bool
    }
}
