//
//  MiragePeerAdvertisementMetadataTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
@testable import MirageConnectivity
import MirageMedia
import MirageWire
import Testing
import MirageConnectivity

@Suite("Mirage Peer Advertisement Metadata")
struct MiragePeerAdvertisementMetadataTests {
    @Test("Host advertisement metadata round trips through Loom TXT records")
    func hostAdvertisementMetadataRoundTripsThroughTXTRecords() {
        let deviceID = UUID()
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: deviceID,
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName(
                processHostName: "Studio Mac"
            ),
            vpnAccessEnabled: true,
            supportedColorDepths: [.pro, .standard],
            supportsProRes4444: true
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(decoded.protocolVersion == Int(MirageWireProtocol.currentDiscoveryVersion))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from: decoded) == 260604)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.controlProtocolVersion(from: decoded) == 260605)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.mediaPacketProtocolVersion(from: decoded) == 260604)
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.identityKeyID == "test-key-id")
        #expect(decoded.deviceType == .mac)
        #expect(decoded.hostName == "Studio-Mac.local")
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.maxStreams(from: decoded) == 4)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.availabilityReason(in: decoded) == .available)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.vpnAccessEnabled(in: decoded))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsHEVC(in: decoded))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: decoded))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsProRes4444(in: decoded))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.maxFrameRate(from: decoded) == 120)
        #expect(decoded.mirageDiscoveryProtocolVersion == 260604)
        #expect(decoded.mirageControlProtocolVersion == 260605)
        #expect(decoded.mirageMediaPacketProtocolVersion == 260604)
        #expect(decoded.mirageMaxStreams == 4)
        #expect(decoded.mirageAcceptingConnections)
        #expect(decoded.mirageAvailabilityReason == .available)
        #expect(decoded.mirageVPNAccessEnabled)
        #expect(decoded.mirageSupportsHEVC)
        #expect(decoded.mirageSupportsP3ColorSpace)
        #expect(decoded.mirageSupportedColorDepths == [.standard, .pro])
        #expect(decoded.mirageSupportsProRes4444)
        #expect(decoded.mirageMaxFrameRate == 120)
    }

    @Test("Local network context preserves host advertisement fields")
    func localNetworkContextPreservesHostAdvertisementFields() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageWireProtocol.currentDiscoveryVersion),
            deviceID: UUID(),
            identityKeyID: "host-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: "Altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
            ],
            metadata: [
                "mirage.accepting-connections": "1",
            ]
        )

        let updated = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            MirageConnectivity.MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:wifi-a", "24:wifi-b"],
                wiredSubnetSignatures: ["24:wired-a"]
            ),
            in: advertisement
        )
        let decoded = LoomPeerAdvertisement.from(txtRecord: updated.toTXTRecord())
        let networkContext = MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(from: decoded)

        #expect(decoded.hostName == "Altair.local")
        #expect(decoded.directTransports == advertisement.directTransports)
        #expect(networkContext.wifiSubnetSignatures == ["24:wifi-a", "24:wifi-b"])
        #expect(networkContext.wiredSubnetSignatures == ["24:wired-a"])
        #expect(networkContext.allSubnetSignatures == ["24:wifi-a", "24:wifi-b", "24:wired-a"])
    }

    @Test("Bound direct transport ports preserve host advertisement fields")
    func boundDirectTransportPortsPreserveHostAdvertisementFields() {
        let baseAdvertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageWireProtocol.currentDiscoveryVersion),
            deviceID: UUID(),
            identityKeyID: "identity-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,5",
            iconName: "macstudio",
            machineFamily: "desktop",
            hostName: "altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 1,
                    pathKind: .wifi
                ),
            ],
            metadata: ["mirage.vpn-access": "1"]
        )

        let updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingDirectTransportPorts(
            [
                .udp: 53812,
                .quic: 64995,
                .tcp: 53812,
            ],
            in: baseAdvertisement
        )

        #expect(updatedAdvertisement.protocolVersion == baseAdvertisement.protocolVersion)
        #expect(updatedAdvertisement.deviceID == baseAdvertisement.deviceID)
        #expect(updatedAdvertisement.identityKeyID == baseAdvertisement.identityKeyID)
        #expect(updatedAdvertisement.deviceType == baseAdvertisement.deviceType)
        #expect(updatedAdvertisement.modelIdentifier == baseAdvertisement.modelIdentifier)
        #expect(updatedAdvertisement.iconName == baseAdvertisement.iconName)
        #expect(updatedAdvertisement.machineFamily == baseAdvertisement.machineFamily)
        #expect(updatedAdvertisement.hostName == baseAdvertisement.hostName)
        #expect(updatedAdvertisement.metadata == baseAdvertisement.metadata)
        #expect(updatedAdvertisement.directTransports == [
            LoomDirectTransportAdvertisement(transportKind: .tcp, port: 53812),
            LoomDirectTransportAdvertisement(transportKind: .quic, port: 64995),
            LoomDirectTransportAdvertisement(transportKind: .udp, port: 53812, pathKind: .wifi),
        ])
    }

    @Test("Identity key updates preserve host advertisement fields")
    func identityKeyUpdatesPreserveHostAdvertisementFields() {
        let baseAdvertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageWireProtocol.currentDiscoveryVersion),
            deviceID: UUID(),
            identityKeyID: "old-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,5",
            iconName: "macstudio",
            machineFamily: "desktop",
            hostName: "altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: 53812,
                    pathKind: .wifi
                ),
            ],
            metadata: ["mirage.vpn-access": "1"]
        )

        let updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingIdentityKeyID(
            "new-key",
            in: baseAdvertisement
        )
        let clearedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingIdentityKeyID(
            nil,
            in: updatedAdvertisement
        )

        #expect(updatedAdvertisement.protocolVersion == baseAdvertisement.protocolVersion)
        #expect(updatedAdvertisement.deviceID == baseAdvertisement.deviceID)
        #expect(updatedAdvertisement.identityKeyID == "new-key")
        #expect(updatedAdvertisement.deviceType == baseAdvertisement.deviceType)
        #expect(updatedAdvertisement.modelIdentifier == baseAdvertisement.modelIdentifier)
        #expect(updatedAdvertisement.iconName == baseAdvertisement.iconName)
        #expect(updatedAdvertisement.machineFamily == baseAdvertisement.machineFamily)
        #expect(updatedAdvertisement.hostName == baseAdvertisement.hostName)
        #expect(updatedAdvertisement.directTransports == baseAdvertisement.directTransports)
        #expect(updatedAdvertisement.metadata == baseAdvertisement.metadata)
        #expect(clearedAdvertisement.identityKeyID == nil)
        #expect(clearedAdvertisement.directTransports == baseAdvertisement.directTransports)
        #expect(clearedAdvertisement.metadata == baseAdvertisement.metadata)
    }

    @Test("Protocol metadata falls back to Loom advertisement version")
    func protocolMetadataFallsBackToLoomAdvertisementVersion() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: 12345,
            deviceID: UUID(),
            identityKeyID: "legacy-key",
            deviceType: .mac
        )

        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from: advertisement) == 12345)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.controlProtocolVersion(from: advertisement) == 12345)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.mediaPacketProtocolVersion(from: advertisement) == 12345)
    }

    @Test("Client advertisement uses current Mirage discovery protocol")
    func clientAdvertisementUsesCurrentMirageDiscoveryProtocol() {
        let deviceID = UUID()
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: .iPad,
            identityKeyID: "client-key",
            additionalMetadata: ["mirage.client": "1"]
        )

        #expect(advertisement.protocolVersion == Int(MirageWireProtocol.currentDiscoveryVersion))
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from: advertisement) == 260604)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.controlProtocolVersion(from: advertisement) == 260605)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.mediaPacketProtocolVersion(from: advertisement) == 260604)
        #expect(advertisement.deviceID == deviceID)
        #expect(advertisement.identityKeyID == "client-key")
        #expect(advertisement.metadata["mirage.client"] == "1")
    }
}
