//
//  ClientConnectionEndpointAddressPlanningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Loom
import Network
import Testing

@Suite("Client Connection Endpoint Address Planning")
struct ClientConnectionEndpointAddressPlanningTests {
    @MainActor
    @Test("Client keeps same-subnet Bonjour resolved addresses when peer-to-peer is enabled")
    func controlSessionAttemptsPreferResolvedAddressOnSameSubnet() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61025))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ],
                metadata: [
                    "mirage.net.wifi": "24:sharedwifi",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:sharedwifi"],
                wiredSubnetSignatures: []
            )
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client prefers Bonjour hostname over off-subnet resolved addresses for peer-to-peer")
    func controlSessionAttemptsPreferBonjourHostnameForPeerToPeerAcrossSubnets() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61026))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61027))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.net.wifi": "24:hostwifi",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:clientwifi"],
                wiredSubnetSignatures: []
            )
        )
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: udpPort
        )
        let expectedTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: tcpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
        #expect(attempts[1].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client keeps off-subnet resolved addresses when peer-to-peer is disabled")
    func controlSessionAttemptsKeepResolvedAddressAcrossSubnetsWhenPeerToPeerDisabled() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61028))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ],
                metadata: [
                    "mirage.net.wifi": "24:hostwifi",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ]
        )

        let service = MirageClientService(
            deviceName: "Test Device",
            loomConfiguration: LoomNetworkConfiguration(enablePeerToPeer: false)
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:clientwifi"],
                wiredSubnetSignatures: []
            )
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client falls back to overlay resolved address when no local addresses exist")
    func controlSessionAttemptsFallBackToOverlayResolvedAddress() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61022))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("100.65.199.51"))),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let udpAttempt = try #require(attempts.first { $0.transportKind == .udp })
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("100.65.199.51"))),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(udpAttempt.endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client skips local network mismatch diagnosis on AWDL")
    func localNetworkMismatchReasonSkipsAwdl() {
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: "altair.local", port: 6100),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                metadata: [
                    "mirage.net.wifi": "24:hostwifi",
                ]
            )
        )

        let reason = MirageClientService.localNetworkMismatchReason(
            for: host,
            classification: .timeout,
            localNetwork: MirageClientService.ControlSessionNetworkDiagnostics(
                currentPathKind: .awdl,
                wifiSubnetSignatures: ["24:clientwifi"],
                wiredSubnetSignatures: []
            )
        )

        #expect(reason == nil)
    }

    @MainActor
    @Test("Local network mismatch reason uses Proximity Connect wording")
    func localNetworkMismatchReasonUsesProximityConnectWording() throws {
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: "altair.local", port: 6100),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                metadata: [
                    "mirage.net.wifi": "24:hostwifi",
                ]
            )
        )

        let reason = MirageClientService.localNetworkMismatchReason(
            for: host,
            classification: .timeout,
            localNetwork: MirageClientService.ControlSessionNetworkDiagnostics(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:clientwifi"],
                wiredSubnetSignatures: []
            )
        )
        let message = try #require(reason)

        #expect(message.contains("Proximity Connect"))
        #expect(message.contains("Network settings"))
        #expect(!message.lowercased().contains("peer-to-peer"))
    }
}
