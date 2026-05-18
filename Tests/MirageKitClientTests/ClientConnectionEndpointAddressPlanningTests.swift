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
    @Test("Client tries AWDL Bonjour hostname before resolved IP fallback")
    func controlSessionAttemptsPreferAwdlBeforeResolvedAddressFallback() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61029))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61033))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61030))
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
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.net.wifi": "24:sharedwifi",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
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
        let expectedAwdlUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: udpPort
        )
        let expectedAwdlTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: tcpPort
        )
        let expectedAwdlQUICEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: quicPort
        )
        let expectedFallbackUDPEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )
        let expectedFallbackQUICEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: quicPort
        )
        let expectedFallbackTCPEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: tcpPort
        )

        #expect(attempts.count == 6)
        #expect(attempts.map(\.transportKind) == [.udp, .quic, .tcp, .udp, .quic, .tcp])
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].endpoint.debugDescription == expectedAwdlUDPEndpoint.debugDescription)
        #expect(attempts[1].isPeerToPeerPreferred)
        #expect(attempts[1].endpoint.debugDescription == expectedAwdlQUICEndpoint.debugDescription)
        #expect(attempts[2].isPeerToPeerPreferred)
        #expect(attempts[2].endpoint.debugDescription == expectedAwdlTCPEndpoint.debugDescription)
        #expect(!attempts[3].isPeerToPeerPreferred)
        #expect(attempts[3].endpoint.debugDescription == expectedFallbackUDPEndpoint.debugDescription)
        #expect(!attempts[4].isPeerToPeerPreferred)
        #expect(attempts[4].endpoint.debugDescription == expectedFallbackQUICEndpoint.debugDescription)
        #expect(!attempts[5].isPeerToPeerPreferred)
        #expect(attempts[5].endpoint.debugDescription == expectedFallbackTCPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client keeps resolved IP first when peer-to-peer is disabled")
    func controlSessionAttemptsDoNotPreferAwdlWhenPeerToPeerDisabled() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61031))
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
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
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
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("AWDL attempts use short timeout before fallback")
    func awdlAttemptsUseShortTimeoutBeforeFallback() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61032))
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
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)

        #expect(attempts.count == 3)
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(service.controlSessionConnectTimeout(for: attempts[0]) == .seconds(2))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[0]) == .seconds(6))
        #expect(!attempts[1].isPeerToPeerPreferred)
        #expect(service.controlSessionConnectTimeout(for: attempts[1]) == .seconds(5))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[1]) == .seconds(20))
    }

    @MainActor
    @Test("Client tries optimistic peer-to-peer before same-subnet resolved IP fallback")
    func controlSessionAttemptsPreferOptimisticPeerToPeerBeforeResolvedAddressOnSameSubnet() throws {
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
        let expectedPeerToPeerEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: udpPort
        )

        #expect(attempts.count == 3)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].requiredInterfaceType == .other)
        #expect(attempts[0].endpoint.debugDescription == expectedPeerToPeerEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .udp)
        #expect(!attempts[1].isPeerToPeerPreferred)
        #expect(attempts[1].endpoint.debugDescription == expectedEndpoint.debugDescription)
        #expect(attempts[2].transportKind == .tcp)
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

        #expect(attempts.count == 4)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
        #expect(attempts[1].isPeerToPeerPreferred)
        #expect(attempts[1].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
        #expect(!attempts[2].isPeerToPeerPreferred)
        #expect(attempts[2].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(!attempts[3].isPeerToPeerPreferred)
        #expect(attempts[3].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
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
        let udpAttempt = try #require(
            attempts.first { $0.transportKind == .udp && !$0.isPeerToPeerPreferred }
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("100.65.199.51"))),
            port: udpPort
        )

        #expect(attempts.count == 3)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].isPeerToPeerPreferred)
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
