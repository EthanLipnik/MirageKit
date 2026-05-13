//
//  MirageKitPeerAdvertisementTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("MirageKit Peer Advertisement")
struct MirageKitPeerAdvertisementTests {
    @Test("Peer advertisement TXT record")
    func peerAdvertisementTXTRecord() {
        let deviceID = UUID()
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: deviceID,
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            supportedColorDepths: [.standard, .pro]
        )

        let txtRecord = advertisement.toTXTRecord()
        #expect(txtRecord["proto"] == String(Int(MirageKit.protocolVersion)))
        #expect(txtRecord["did"] == deviceID.uuidString)
        #expect(txtRecord["ikid"] == "test-key-id")
        #expect(txtRecord["dt"] == DeviceType.mac.rawValue)
        #expect(txtRecord["model"] == "Mac16,1")
        #expect(txtRecord["icon"] == "desktopcomputer")
        #expect(txtRecord["family"] == "Mac")

        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(decoded.protocolVersion == Int(MirageKit.protocolVersion))
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.identityKeyID == "test-key-id")
        #expect(decoded.deviceType == .mac)
        #expect(decoded.hostName == MiragePeerAdvertisementMetadata.advertisedBonjourHostName())
        #expect(MiragePeerAdvertisementMetadata.maxStreams(from: decoded) == 4)
        #expect(MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportsHEVC(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MiragePeerAdvertisementMetadata.supportsProRes4444(in: decoded) == false)
        #expect(MiragePeerAdvertisementMetadata.maxFrameRate(from: decoded) == 120)
        #expect(decoded.mirageAcceptingConnections == true)
    }

    @Test("Peer advertisement ProRes support round trips separately from HEVC Ultra")
    func peerAdvertisementProResSupportRoundTripsSeparatelyFromUltraColorDepth() {
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            supportedColorDepths: [.standard, .pro],
            supportsProRes4444: true
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MiragePeerAdvertisementMetadata.supportsProRes4444(in: decoded))
        #expect(decoded.mirageSupportsProRes4444)
    }

    @Test("Peer advertisement busy flag round trips")
    func peerAdvertisementBusyFlagRoundTrips() {
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: false,
            supportedColorDepths: [.standard]
        )

        let txtRecord = advertisement.toTXTRecord()
        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == false)
        #expect(decoded.mirageAcceptingConnections == false)
    }

    @Test("Unknown video codec in stream requests is rejected")
    func unknownVideoCodecInStreamRequestsIsRejected() {
        let startStream = Data(#"{"windowID":1,"targetFrameRate":60,"codec":"future-codec"}"#.utf8)
        let selectApp = Data((
            #"{"startupRequestID":"00000000-0000-0000-0000-000000001523","# +
                #""appSessionID":"00000000-0000-0000-0000-000000001524","# +
                #""bundleIdentifier":"com.example.Editor","targetFrameRate":60,"# +
                #""maxConcurrentVisibleWindows":1,"codec":"future-codec"}"#
        ).utf8)
        let customStream = Data((
            #"{"startupRequestID":"00000000-0000-0000-0000-000000001525","# +
                #""kind":"com.example.custom","metadata":{},"displayWidth":1280,"# +
                #""displayHeight":720,"targetFrameRate":60,"codec":"future-codec"}"#
        ).utf8)

        #expect(throws: Error.self) {
            try JSONDecoder().decode(StartStreamMessage.self, from: startStream)
        }
        #expect(throws: Error.self) {
            try JSONDecoder().decode(SelectAppMessage.self, from: selectApp)
        }
        #expect(throws: Error.self) {
            try JSONDecoder().decode(StartCustomStreamMessage.self, from: customStream)
        }
    }

    @Test("Peer advertisement local network context round trips and preserves host fields")
    func peerAdvertisementLocalNetworkContextRoundTrips() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.protocolVersion),
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

        let updated = MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:wifi-a", "24:wifi-b"],
                wiredSubnetSignatures: ["24:wired-a"]
            ),
            in: advertisement
        )
        let decoded = LoomPeerAdvertisement.from(txtRecord: updated.toTXTRecord())
        let networkContext = MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(from: decoded)

        #expect(decoded.hostName == "Altair.local")
        #expect(decoded.directTransports == advertisement.directTransports)
        #expect(networkContext.wifiSubnetSignatures == ["24:wifi-a", "24:wifi-b"])
        #expect(networkContext.wiredSubnetSignatures == ["24:wired-a"])
    }

    @Test("Host advertisement VPN access metadata serialization")
    func hostAdvertisementVPNAccessMetadataSerialization() {
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "host-key",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: true,
            vpnAccessEnabled: true,
            supportedColorDepths: [.standard, .pro]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(decoded.mirageAcceptingConnections == true)
        #expect(decoded.mirageVPNAccessEnabled == true)
    }
}
