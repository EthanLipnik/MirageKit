//
//  ClientConnectionEndpointPlanningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
import Testing

@Suite("Client Connection Endpoint Planning")
struct ClientConnectionEndpointPlanningTests {
    @Test("Peer advertisement round-trips hostName through TXT record")
    func hostNameRoundTrips() throws {
        let original = LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: UUID(),
            identityKeyID: "host-key",
            deviceType: .mac,
            hostName: "Ethans-Mac-Studio.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
            ]
        )

        let txt = original.toTXTRecord()
        let decoded = LoomPeerAdvertisement.from(txtRecord: txt)

        #expect(decoded.hostName == "Ethans-Mac-Studio.local")
        #expect(decoded.directTransports.first(where: { $0.transportKind == .udp })?.port == 61001)
    }

    @Test("Peer advertisement without hostName decodes as nil")
    func missingHostNameDecodesAsNil() throws {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: UUID()
        )

        let txt = advertisement.toTXTRecord()
        let decoded = LoomPeerAdvertisement.from(txtRecord: txt)

        #expect(decoded.hostName == nil)
    }
}
