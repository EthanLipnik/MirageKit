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
    @Test("Client ranks proximity Bonjour interfaces before resolved IP fallback")
    func controlSessionAttemptsRankProximityInterfacesBeforeFallback() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61040))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61041))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61042))
        let anpiAddress = try #require(IPv6Address("fe80::1%anpi0"))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let llwAddress = try #require(IPv6Address("fe80::3%llw0"))
        let bridgeAddress = try #require(IPv6Address("fe80::4%bridge100"))
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
                .ipv6(anpiAddress),
                .ipv6(awdlAddress),
                .ipv6(llwAddress),
                .ipv6(bridgeAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
                LoomDiscoveredInterface(name: "bridge100", type: .other, index: 14),
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
                LoomDiscoveredInterface(name: "en3", type: .wiredEthernet, index: 10),
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
                LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
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
        let proximityAttempts = Array(attempts.prefix(12))
        let fallbackAttempts = Array(attempts.suffix(3))

        #expect(attempts.count == 15)
        #expect(proximityAttempts.allSatisfy { $0.isPeerToPeerPreferred })
        #expect(proximityAttempts.map { $0.proximityInterfaceNames.first ?? "" } == [
            "anpi0", "anpi0", "anpi0",
            "bridge100", "bridge100", "bridge100",
            "llw0", "llw0", "llw0",
            "awdl0", "awdl0", "awdl0",
        ])
        #expect(proximityAttempts.map(\.routeTier) == [
            .applePrivateNCM, .applePrivateNCM, .applePrivateNCM,
            .bridge, .bridge, .bridge,
            .lowLatencyWireless, .lowLatencyWireless, .lowLatencyWireless,
            .awdl, .awdl, .awdl,
        ])
        #expect(proximityAttempts.map(\.transportKind) == [
            .udp, .quic, .tcp,
            .udp, .quic, .tcp,
            .udp, .quic, .tcp,
            .udp, .quic, .tcp,
        ])
        #expect(fallbackAttempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(fallbackAttempts.map(\.transportKind) == [.udp, .quic, .tcp])
        #expect(fallbackAttempts.map(\.routeTier) == [.wifiLAN, .wifiLAN, .wifiLAN])
    }

    @MainActor
    @Test("Client can prefer Wi-Fi LAN attempts before AWDL while keeping other proximity routes first")
    func controlSessionAttemptsPreferWiFiBeforeAwdlWhenRequested() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61046))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61047))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61048))
        let anpiAddress = try #require(IPv6Address("fe80::1%anpi0"))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let llwAddress = try #require(IPv6Address("fe80::3%llw0"))
        let bridgeAddress = try #require(IPv6Address("fe80::4%bridge100"))
        let wifiAddress = try #require(IPv4Address("192.168.1.50"))
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
                .ipv4(wifiAddress),
                .ipv6(anpiAddress),
                .ipv6(awdlAddress),
                .ipv6(llwAddress),
                .ipv6(bridgeAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
                LoomDiscoveredInterface(name: "bridge100", type: .other, index: 14),
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferWiFiBeforeAwdlProximity = true
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:sharedwifi"],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.map(\.routeTier) == [
            .applePrivateNCM, .applePrivateNCM, .applePrivateNCM,
            .bridge, .bridge, .bridge,
            .lowLatencyWireless, .lowLatencyWireless, .lowLatencyWireless,
            .wifiLAN, .wifiLAN, .wifiLAN,
            .awdl, .awdl, .awdl,
        ])
        #expect(attempts.prefix(9).allSatisfy { $0.isPeerToPeerPreferred })
        #expect(attempts[9..<12].allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.suffix(3).allSatisfy { $0.isPeerToPeerPreferred })
    }

    @MainActor
    @Test("Client ranks same wired Ethernet before AWDL")
    func controlSessionAttemptsRankSameWiredEthernetBeforeAwdl() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61043))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61044))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61045))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
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
                    "mirage.net.wired": "24:wired",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
                .ipv6(awdlAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
                LoomDiscoveredInterface(name: "en3", type: .wiredEthernet, index: 10),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wired,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: ["24:wired"]
            )
        )
        let proximityAttempts = attempts.filter(\.isPeerToPeerPreferred)

        #expect(proximityAttempts.map(\.routeTier) == [
            .sameWiredEthernet, .sameWiredEthernet, .sameWiredEthernet,
            .awdl, .awdl, .awdl,
        ])
        #expect(proximityAttempts.prefix(3).allSatisfy { $0.proximityInterfaceNames == ["en3"] })
    }

    @MainActor
    @Test("Client ranks mixed Ethernet same LAN after AWDL before Wi-Fi LAN")
    func controlSessionAttemptsRankMixedEthernetSameLANAfterAwdlBeforeWiFiLAN() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61046))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61047))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61048))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
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
                    "mirage.net.wired": "24:shared",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
                .ipv6(awdlAddress),
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
                wifiSubnetSignatures: ["24:shared"],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.map(\.routeTier) == [
            .awdl, .awdl, .awdl,
            .mixedEthernetSameLAN, .mixedEthernetSameLAN, .mixedEthernetSameLAN,
        ])
        #expect(attempts.prefix(3).allSatisfy { $0.isPeerToPeerPreferred })
        #expect(attempts.suffix(3).allSatisfy { !$0.isPeerToPeerPreferred })
    }

    @MainActor
    @Test("Client does not prioritize Ethernet when wired subnet signatures do not intersect")
    func controlSessionAttemptsDoNotPrioritizeEthernetWithoutSubnetIntersection() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61049))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61050))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61051))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
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
                    "mirage.net.wired": "24:hostwired",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
                .ipv6(awdlAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en3", type: .wiredEthernet, index: 10),
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wired,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: ["24:clientwired"]
            )
        )
        let proximityAttempts = attempts.filter(\.isPeerToPeerPreferred)

        #expect(proximityAttempts.map(\.routeTier) == [.awdl, .awdl, .awdl])
        #expect(proximityAttempts.allSatisfy { $0.proximityInterfaceNames == ["awdl0"] })
        #expect(!attempts.contains { $0.routeTier == .sameWiredEthernet })
    }

    @MainActor
    @Test("Explicit VPN route skips local candidates and starts QUIC first")
    func explicitVPNRouteSkipsLocalCandidatesAndStartsQUICFirst() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61052))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61053))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61054))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: .ipv4(#require(IPv4Address("100.65.199.51"))), port: quicPort),
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
                    "mirage.connection-origin": "remote",
                    "mirage.net.wifi": "24:sharedwifi",
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
                .ipv6(awdlAddress),
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

        #expect(attempts.count == 3)
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.map(\.candidateKind) == [.overlay, .overlay, .overlay])
        #expect(attempts.map(\.routeTier) == [.vpn, .vpn, .vpn])
        #expect(attempts.map(\.transportKind) == [.quic, .udp, .tcp])
        #expect(service.controlSessionInitialConnectTimeout(for: attempts[0]) == .seconds(6))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[0]) == .seconds(30))
    }

    @MainActor
    @Test("Client tries scoped AWDL address before resolved IP fallback")
    func controlSessionAttemptsPreferScopedAwdlBeforeResolvedAddressFallback() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61029))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61033))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61030))
        let awdlAddress = try #require(IPv6Address("fe80::5%awdl0"))
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
                .ipv6(awdlAddress),
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
            host: .ipv6(awdlAddress),
            port: udpPort
        )
        let expectedAwdlTCPEndpoint: NWEndpoint = .hostPort(
            host: .ipv6(awdlAddress),
            port: tcpPort
        )
        let expectedAwdlQUICEndpoint: NWEndpoint = .hostPort(
            host: .ipv6(awdlAddress),
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
    @Test("Suppressed AWDL route falls back to local LAN candidates")
    func suppressedAwdlRouteFallsBackToLocalLANCandidates() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61055))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61056))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61057))
        let awdlAddress = try #require(IPv6Address("fe80::5%awdl0"))
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
                .ipv6(awdlAddress),
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.suppressAwdlProximityRoute(
            for: host,
            interfaceNames: ["awdl0"],
            duration: 900,
            reason: "unit test"
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:sharedwifi"],
                wiredSubnetSignatures: []
            )
        )
        let expectedFallbackUDPEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )

        #expect(attempts.count == 3)
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(!attempts.contains { $0.routeTier == .awdl })
        #expect(attempts.map(\.transportKind) == [.udp, .quic, .tcp])
        #expect(attempts[0].endpoint.debugDescription == expectedFallbackUDPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Forced AWDL route ignores active AWDL suppression")
    func forcedAwdlRouteIgnoresActiveSuppression() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61055))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61056))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61057))
        let awdlAddress = try #require(IPv6Address("fe80::5%awdl0"))
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
                .ipv6(awdlAddress),
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.suppressAwdlProximityRoute(
            for: host,
            interfaceNames: ["awdl0"],
            duration: 900,
            reason: "unit test"
        )
        service.debugRouteOverride = MirageDebugRouteOverride(
            transportKind: .udp,
            interfaceKind: .awdl,
            interfaceName: "awdl0"
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:sharedwifi"],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].routeTier == .awdl)
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].proximityInterfaceNames == ["awdl0"])
    }

    @MainActor
    @Test("Forced unavailable interface produces no connection attempts")
    func forcedUnavailableInterfaceProducesNoAttempts() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61058))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61059))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61060))
        let awdlAddress = try #require(IPv6Address("fe80::6%awdl0"))
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
                ]
            ),
            resolvedAddresses: [.ipv6(awdlAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.debugRouteOverride = MirageDebugRouteOverride(
            transportKind: .udp,
            interfaceKind: .awdl,
            interfaceName: "awdl99"
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.isEmpty)
    }

    @MainActor
    @Test("Forced Wi-Fi route falls back to route kind when exact interface evidence is unavailable")
    func forcedWiFiRouteMatchesRouteKindWithoutExactInterfaceEvidence() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61061))
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
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.debugRouteOverride = MirageDebugRouteOverride(
            transportKind: .udp,
            interfaceKind: .wifi,
            interfaceName: "en0"
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:sharedwifi"],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].routeTier == .wifiLAN)
    }

    @MainActor
    @Test("Client uses scoped link-local addresses matching discovered proximity interfaces")
    func controlSessionAttemptsUseScopedLinkLocalAddressForMatchingProximityInterface() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61034))
        let anpiAddress = try #require(IPv6Address("fe80::1%anpi0"))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let host = LoomPeer(
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
                .ipv6(awdlAddress),
                .ipv6(anpiAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
                LoomDiscoveredInterface(name: "anpi0", type: .other, index: 9),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let proximityAttempts = attempts.filter { $0.isPeerToPeerPreferred && $0.transportKind == .udp }
        let expectedAnpiEndpoint: NWEndpoint = .hostPort(host: .ipv6(anpiAddress), port: udpPort)
        let expectedAwdlEndpoint: NWEndpoint = .hostPort(host: .ipv6(awdlAddress), port: udpPort)

        #expect(proximityAttempts.count == 2)
        #expect(proximityAttempts[0].endpoint.debugDescription == expectedAnpiEndpoint.debugDescription)
        #expect(proximityAttempts[0].proximityInterfaceNames == ["anpi0"])
        #expect(proximityAttempts[1].endpoint.debugDescription == expectedAwdlEndpoint.debugDescription)
        #expect(proximityAttempts[1].proximityInterfaceNames == ["awdl0"])
    }

    @MainActor
    @Test("Client orders optimistic scoped proximity addresses by interface priority")
    func optimisticControlSessionAttemptsOrderScopedProximityAddressesByInterfacePriority() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61035))
        let anpiAddress = try #require(IPv6Address("fe80::3%anpi0"))
        let awdlAddress = try #require(IPv6Address("fe80::4%awdl0"))
        let host = LoomPeer(
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
                .ipv6(awdlAddress),
                .ipv6(anpiAddress),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let proximityAttempts = attempts.filter { $0.isPeerToPeerPreferred && $0.transportKind == .udp }
        let expectedAnpiEndpoint: NWEndpoint = .hostPort(host: .ipv6(anpiAddress), port: udpPort)
        let expectedAwdlEndpoint: NWEndpoint = .hostPort(host: .ipv6(awdlAddress), port: udpPort)

        #expect(proximityAttempts.count == 2)
        #expect(proximityAttempts[0].endpoint.debugDescription == expectedAnpiEndpoint.debugDescription)
        #expect(proximityAttempts[0].proximityInterfaceNames == ["anpi0"])
        #expect(proximityAttempts[1].endpoint.debugDescription == expectedAwdlEndpoint.debugDescription)
        #expect(proximityAttempts[1].proximityInterfaceNames == ["awdl0"])
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
        let awdlAddress = try #require(IPv6Address("fe80::6%awdl0"))
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
                .ipv6(awdlAddress),
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
    @Test("Client skips optimistic peer-to-peer without proximity evidence")
    func controlSessionAttemptsSkipOptimisticPeerToPeerWithoutProximityEvidence() throws {
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
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client prefers Bonjour hostname over off-subnet resolved addresses without proximity label")
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
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
        #expect(!attempts[1].isPeerToPeerPreferred)
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
        let udpAttempt = try #require(
            attempts.first { $0.transportKind == .udp && !$0.isPeerToPeerPreferred }
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("100.65.199.51"))),
            port: udpPort
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].transportKind == .udp)
        #expect(!attempts[0].isPeerToPeerPreferred)
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

    @Test("Proximity path validation rejects ordinary Wi-Fi fallback paths")
    func proximityPathValidationRejectsOrdinaryWiFiFallback() {
        let attempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: "altair.local", port: 61040),
            transportKind: .udp,
            candidateKind: .local,
            isPeerToPeerPreferred: true,
            proximityInterfaceKind: .applePrivateNCM,
            proximityInterfaceNames: ["anpi0"]
        )
        let anpiSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["anpi0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let wifiSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(attempt.acceptsProximityPath(anpiSnapshot))
        #expect(!attempt.acceptsProximityPath(wifiSnapshot))
    }

    @Test("Optimistic proximity validation accepts only proximity-like paths")
    func optimisticProximityPathValidationRequiresProximityPath() {
        let attempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: "altair.local", port: 61040),
            transportKind: .udp,
            candidateKind: .local,
            requiredInterfaceType: .other,
            isPeerToPeerPreferred: true
        )
        let llwSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["llw0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let wiredSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en3"],
            usesWiFi: false,
            usesWired: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let wifiSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let overlaySnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["utun5"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let genericOtherSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["other0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(attempt.acceptsProximityPath(llwSnapshot))
        #expect(attempt.acceptsProximityPath(wiredSnapshot))
        #expect(!attempt.acceptsProximityPath(wifiSnapshot))
        #expect(!attempt.acceptsProximityPath(overlaySnapshot))
        #expect(!attempt.acceptsProximityPath(genericOtherSnapshot))
    }
}
