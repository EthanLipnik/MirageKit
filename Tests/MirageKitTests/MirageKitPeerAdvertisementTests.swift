//
//  MirageKitPeerAdvertisementTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Network
import Loom
@testable import MirageKit
import Testing
import MirageConnectivity
import MirageKit
import MirageWire

@Suite("MirageKit Peer Advertisement")
struct MirageKitPeerAdvertisementTests {
    @Test("Peer advertisement TXT record")
    func peerAdvertisementTXTRecord() {
        let deviceID = UUID()
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: deviceID,
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            supportedColorDepths: [.standard, .pro]
        )

        let txtRecord = advertisement.toTXTRecord()
        #expect(txtRecord["proto"] == String(Int(MirageKit.discoveryProtocolVersion)))
        #expect(txtRecord["mirage.protocol.discovery"] == String(Int(MirageKit.discoveryProtocolVersion)))
        #expect(txtRecord["mirage.protocol.control"] == String(Int(MirageKit.controlProtocolVersion)))
        #expect(txtRecord["mirage.protocol.media"] == String(Int(MirageKit.mediaPacketProtocolVersion)))
        #expect(txtRecord["did"] == deviceID.uuidString)
        #expect(txtRecord["ikid"] == "test-key-id")
        #expect(txtRecord["dt"] == DeviceType.mac.rawValue)
        #expect(txtRecord["model"] == "Mac16,1")
        #expect(txtRecord["icon"] == "desktopcomputer")
        #expect(txtRecord["family"] == "Mac")

        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(decoded.protocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(decoded.mirageDiscoveryProtocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(decoded.mirageControlProtocolVersion == Int(MirageKit.controlProtocolVersion))
        #expect(decoded.mirageMediaPacketProtocolVersion == Int(MirageKit.mediaPacketProtocolVersion))
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.identityKeyID == "test-key-id")
        #expect(decoded.deviceType == .mac)
        #expect(decoded.hostName == MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName())
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.maxStreams(from: decoded) == 4)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == true)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsHEVC(in: decoded) == true)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: decoded) == true)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsProRes4444(in: decoded) == false)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.maxFrameRate(from: decoded) == 120)
        #expect(decoded.mirageOperatingSystemName == "macOS")
        #expect(decoded.mirageOperatingSystemVersion == Self.currentOperatingSystemVersionString)
        #expect(decoded.mirageOperatingSystemMajorVersion == ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #expect(decoded.mirageAcceptingConnections == true)
        let availabilityReason: MirageConnectivity.MirageHostAdvertisementAvailabilityReason = decoded.mirageAvailabilityReason
        #expect(availabilityReason == .available)
    }

    @Test("Peer advertisement ProRes support round trips separately from HEVC Ultra")
    func peerAdvertisementProResSupportRoundTripsSeparatelyFromUltraColorDepth() {
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            supportedColorDepths: [.standard, .pro],
            supportsProRes4444: true
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.supportsProRes4444(in: decoded))
        #expect(decoded.mirageSupportsProRes4444)
    }

    @Test("Peer advertisement busy flag round trips")
    func peerAdvertisementBusyFlagRoundTrips() {
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: false,
            supportedColorDepths: [.standard]
        )

        let txtRecord = advertisement.toTXTRecord()
        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(MirageConnectivity.MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == false)
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
            try JSONDecoder().decode(MirageWire.StartStreamMessage.self, from: startStream)
        }
        #expect(throws: Error.self) {
            try JSONDecoder().decode(MirageWire.SelectAppMessage.self, from: selectApp)
        }
        #expect(throws: Error.self) {
            try JSONDecoder().decode(MirageWire.StartCustomStreamMessage.self, from: customStream)
        }
    }

    @Test("Peer advertisement local network context round trips and preserves host fields")
    func peerAdvertisementLocalNetworkContextRoundTrips() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.discoveryProtocolVersion),
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
        #expect(decoded.mirageDiscoveryProtocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(decoded.mirageControlProtocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(decoded.mirageMediaPacketProtocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(decoded.directTransports == advertisement.directTransports)
        #expect(networkContext.wifiSubnetSignatures == ["24:wifi-a", "24:wifi-b"])
        #expect(networkContext.wiredSubnetSignatures == ["24:wired-a"])
    }

    @Test("Peer advertisement local endpoint hints round trip and match current network")
    func peerAdvertisementLocalEndpointHintsRoundTripAndMatchCurrentNetwork() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.discoveryProtocolVersion),
            deviceID: UUID(),
            identityKeyID: "host-key",
            deviceType: .mac,
            hostName: "Altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
            ],
            metadata: [
                "mirage.accepting-connections": "1",
            ]
        )

        let updated = MiragePeerAdvertisementMetadata.updatingLocalEndpointHints(
            localEndpointHosts: [
                NWEndpoint.Host("192.168.1.44"),
                NWEndpoint.Host("100.64.12.1"),
                NWEndpoint.Host("169.254.1.9"),
            ],
            localNetwork: MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:wifi-home"],
                wiredSubnetSignatures: []
            ),
            observedAt: observedAt,
            in: advertisement
        )
        let decoded = LoomPeerAdvertisement.from(txtRecord: updated.toTXTRecord())
        let currentNetwork = MirageLocalNetworkSignatureContext(
            wifiSubnetSignatures: ["24:wifi-home"],
            wiredSubnetSignatures: []
        )
        let hints = MiragePeerAdvertisementMetadata.localEndpointHints(from: decoded, now: observedAt)

        #expect(hints.count == 1)
        #expect(hints.first?.hosts == ["192.168.1.44"])
        #expect(decoded.mirageLocalEndpointHost(matching: currentNetwork) == "192.168.1.44")
        #expect(decoded.mirageLocalEndpointHost(
            matching: MirageLocalNetworkSignatureContext(
                wifiSubnetSignatures: ["24:wifi-office"],
                wiredSubnetSignatures: []
            )
        ) == nil)
    }

    @Test("Peer advertisement local endpoint hints expire and stay bounded")
    func peerAdvertisementLocalEndpointHintsExpireAndStayBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        var advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.discoveryProtocolVersion),
            deviceID: UUID(),
            deviceType: .mac,
            hostName: "Altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
            ]
        )

        for (index, signature, ageInDays) in [
            (10, "24:expired", 31),
            (11, "24:older", 4),
            (12, "24:third", 3),
            (13, "24:second", 2),
            (14, "24:first", 1),
        ] {
            advertisement = MiragePeerAdvertisementMetadata.updatingLocalEndpointHints(
                localEndpointHosts: [
                    NWEndpoint.Host("192.168.1.\(index)"),
                ],
                localNetwork: MirageLocalNetworkSnapshot(
                    currentPathKind: .wifi,
                    wifiSubnetSignatures: [signature],
                    wiredSubnetSignatures: []
                ),
                observedAt: now.addingTimeInterval(-TimeInterval(ageInDays) * day),
                in: advertisement
            )
        }

        let hints = MiragePeerAdvertisementMetadata.localEndpointHints(from: advertisement, now: now)

        #expect(hints.count == 3)
        #expect(hints.map(\.network.wifiSubnetSignatures.first) == ["24:first", "24:second", "24:third"])
        #expect(MiragePeerAdvertisementMetadata.bestLocalEndpointHost(
            matching: MirageLocalNetworkSignatureContext(
                wifiSubnetSignatures: ["24:older"],
                wiredSubnetSignatures: []
            ),
            in: advertisement,
            now: now
        ) == nil)
        #expect(MiragePeerAdvertisementMetadata.bestLocalEndpointHost(
            matching: MirageLocalNetworkSignatureContext(
                wifiSubnetSignatures: ["24:expired"],
                wiredSubnetSignatures: []
            ),
            in: advertisement,
            now: now
        ) == nil)
    }

    @Test("Peer advertisement merges previous CloudKit local endpoint hints")
    func peerAdvertisementMergesPreviousCloudKitLocalEndpointHints() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previousAdvertisement = MiragePeerAdvertisementMetadata.updatingLocalEndpointHints(
            localEndpointHosts: [
                NWEndpoint.Host("192.168.10.20"),
            ],
            localNetwork: MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:previous"],
                wiredSubnetSignatures: []
            ),
            observedAt: now.addingTimeInterval(-60),
            in: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.discoveryProtocolVersion),
                deviceID: UUID(),
                deviceType: .mac,
                hostName: "Altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
                ]
            )
        )
        let currentAdvertisement = MiragePeerAdvertisementMetadata.updatingLocalEndpointHints(
            localEndpointHosts: [
                NWEndpoint.Host("192.168.20.30"),
            ],
            localNetwork: MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:current"],
                wiredSubnetSignatures: []
            ),
            observedAt: now,
            in: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.discoveryProtocolVersion),
                deviceID: UUID(),
                deviceType: .mac,
                hostName: "Altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
                ]
            )
        )

        let merged = MiragePeerAdvertisementMetadata.mergingLocalEndpointHints(
            from: previousAdvertisement,
            into: currentAdvertisement,
            now: now
        )

        #expect(MiragePeerAdvertisementMetadata.bestLocalEndpointHost(
            matching: MirageLocalNetworkSignatureContext(
                wifiSubnetSignatures: ["24:current"],
                wiredSubnetSignatures: []
            ),
            in: merged,
            now: now
        ) == "192.168.20.30")
        #expect(MiragePeerAdvertisementMetadata.bestLocalEndpointHost(
            matching: MirageLocalNetworkSignatureContext(
                wifiSubnetSignatures: ["24:previous"],
                wiredSubnetSignatures: []
            ),
            in: merged,
            now: now
        ) == "192.168.10.20")
    }

    @Test("Host advertisement VPN access metadata serialization")
    func hostAdvertisementVPNAccessMetadataSerialization() {
        let advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "host-key",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MirageConnectivity.MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: true,
            vpnAccessEnabled: true,
            supportedColorDepths: [.standard, .pro]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(decoded.mirageAcceptingConnections == true)
        #expect(decoded.mirageVPNAccessEnabled == true)
    }

    private static var currentOperatingSystemVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
