//
//  MirageMediaPathProbeProtocolTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

import Testing
@testable import MirageKit

@Suite("MirageMediaPathProbeProtocol")
struct MirageMediaPathProbeProtocolTests {
    @Test("Probe request serializes to expected size")
    func probeRequestSize() {
        let request = MirageMediaPathProbePacket(
            sequenceNumber: 1,
            timestampNs: 12345
        )
        let data = request.serialize()
        #expect(data.count == MirageMediaPathProbePacket.packetSize)
    }

    @Test("Probe request round-trips through serialization")
    func probeRequestRoundTrip() throws {
        let original = MirageMediaPathProbePacket(
            sequenceNumber: 42,
            timestampNs: 9_876_543_210
        )
        let data = original.serialize()
        let decoded = try MirageMediaPathProbePacket.deserialize(from: data)
        #expect(decoded.sequenceNumber == 42)
        #expect(decoded.timestampNs == 9_876_543_210)
    }

    @Test("Probe deserialization rejects wrong magic")
    func rejectsWrongMagic() {
        var data = MirageMediaPathProbePacket(
            sequenceNumber: 1,
            timestampNs: 100
        ).serialize()
        data[0] = 0xFF
        #expect(throws: (any Error).self) {
            try MirageMediaPathProbePacket.deserialize(from: data)
        }
    }

    @Test("Probe deserialization rejects short data")
    func rejectsShortData() {
        let data = Data([0x4D, 0x49, 0x52, 0x50])
        #expect(throws: (any Error).self) {
            try MirageMediaPathProbePacket.deserialize(from: data)
        }
    }
}
