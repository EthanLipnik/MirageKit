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
import MirageConnectivity
import MirageKit

@Suite("Client Connection Endpoint Address Planning")
struct ClientConnectionEndpointAddressPlanningTests {
    private func expectTCPCompatibilityFallbacksAfterUDP(
        _ attempts: [MirageClientService.ControlSessionAttempt]
    ) {
        var hasSeenTCP = false
        for attempt in attempts {
            if attempt.transportKind == .tcp {
                hasSeenTCP = true
            } else {
                #expect(!hasSeenTCP)
            }
        }
    }

    @Test("Experimental system proximity routing parses environment flag")
    func experimentalSystemProximityRoutingParsesEnvironmentFlag() {
        #expect(MirageClientService.experimentalSystemProximityRoutingEnabled(environment: [
            "MIRAGE_EXPERIMENTAL_SYSTEM_PROXIMITY_ROUTING": "1",
        ]))
        #expect(MirageClientService.experimentalSystemProximityRoutingEnabled(environment: [
            "MIRAGE_EXPERIMENTAL_SYSTEM_PROXIMITY_ROUTING": "true;debug",
        ]))
        #expect(!MirageClientService.experimentalSystemProximityRoutingEnabled(environment: [
            "MIRAGE_EXPERIMENTAL_SYSTEM_PROXIMITY_ROUTING": "0",
        ]))
        #expect(!MirageClientService.experimentalSystemProximityRoutingEnabled(environment: [:]))
    }

    @MainActor
    @Test("Experimental system proximity routing keeps Bonjour TCP after UDP")
    func experimentalSystemProximityRoutingKeepsBonjourTCPAfterUDP() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61150))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61151))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            ),
            experimentalSystemProximityRoutingEnabled: true
        )
        let systemAttempt = try #require(attempts.first {
            $0.endpointSource == "bonjour-system-proximity-service"
        })

        #expect(systemAttempt.endpointSource == "bonjour-system-proximity-service")
        #expect(systemAttempt.transportKind == .tcp)
        #expect(systemAttempt.routeTier == .lowLatencyWireless)
        #expect(systemAttempt.requiredInterface == nil)
        #expect(systemAttempt.requiredInterfaceType == nil)
        #expect(systemAttempt.interfaceDescription == "proximity")
        #expect(systemAttempt.endpoint == .service(
            name: "Altair",
            type: "_mirage._tcp",
            domain: "local",
            interface: nil
        ))

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

        #expect(systemAttempt.acceptsProximityPath(llwSnapshot))
        #expect(!systemAttempt.acceptsProximityPath(wifiSnapshot))
        #expect(attempts.first?.transportKind == .udp)
        #expect(attempts.first { $0.transportKind == .tcp }?.endpointSource == "bonjour-system-proximity-service")
        #expect(attempts.contains { $0.endpointSource == "bonjour-proximity-service" })
    }

    @MainActor
    @Test("Client uses Bonjour service TCP for AWDL when scoped address is unresolved")
    func controlSessionAttemptsUseBonjourServiceTCPWhenAwdlScopedLiteralIsUnresolved() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61050))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61051))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )

        // No awdl0-scoped literal was resolved, so AWDL UDP must not be
        // attempted. The TCP Bonjour service endpoint is still a real service
        // path, so Network.framework can resolve the peer-to-peer route without
        // Mirage inventing an address.
        let awdlAttempts = attempts.filter { $0.routeTier == .awdl }
        #expect(awdlAttempts.count == 1)
        #expect(awdlAttempts[0].transportKind == .tcp)
        #expect(awdlAttempts[0].endpointSource == "bonjour-proximity-service")
        #expect(awdlAttempts[0].endpoint == .service(
            name: "Altair",
            type: "_mirage._tcp",
            domain: "local",
            interface: nil
        ))
        #expect(service.hasPendingAwdlScopedAddressResolution(for: host))
        #expect(!service.shouldWaitForPendingAwdlScopedAddress(host: host, attempts: attempts))
        // LAN fallback is still planned so the connection can avoid waiting for
        // fresher AWDL address evidence when Wi-Fi is viable.
        #expect(!attempts.isEmpty)

        let scopedAwdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let refreshedHost = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: host.advertisement,
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
                .ipv6(scopedAwdlAddress),
            ],
            discoveredInterfaces: host.discoveredInterfaces
        )
        let refreshedAttempts = service.controlSessionAttempts(
            for: refreshedHost,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )

        let refreshedAwdlAttempts = refreshedAttempts.filter { $0.routeTier == .awdl }
        #expect(!service.hasPendingAwdlScopedAddressResolution(for: refreshedHost))
        #expect(refreshedAwdlAttempts.map(\.transportKind) == [.udp])
        #expect(refreshedAwdlAttempts.allSatisfy { $0.isPeerToPeerPreferred })
        #expect(refreshedAwdlAttempts.allSatisfy { $0.proximityInterfaceNames == ["awdl0"] })
        expectTCPCompatibilityFallbacksAfterUDP(refreshedAttempts)
    }

    @MainActor
    @Test("Scoped AWDL direct attempts exclude TCP transport")
    func scopedAwdlDirectAttemptsExcludeTCPTransport() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61052))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61053))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61054))
        let awdlAddress = try #require(IPv6Address("fe80::3%awdl0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv6(awdlAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let awdlAttempts = attempts.filter { $0.routeTier == .awdl }

        #expect(awdlAttempts.map(\.transportKind) == [.udp])
        #expect(awdlAttempts.allSatisfy { $0.isPeerToPeerPreferred })
        #expect(!attempts.contains { $0.transportKind == .tcp })
    }

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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
        #expect(attempts.count == 11)
        #expect(attempts.map { $0.proximityInterfaceNames.first ?? "" } == [
            "anpi0",
            "bridge100",
            "en3",
            "llw0",
            "",
            "awdl0",
            "anpi0",
            "bridge100",
            "en3",
            "llw0",
            "",
        ])
        #expect(attempts.map(\.routeTier) == [
            .applePrivateNCM,
            .bridge,
            .sameWiredEthernet,
            .lowLatencyWireless,
            .wifiLAN,
            .awdl,
            .applePrivateNCM,
            .bridge,
            .sameWiredEthernet,
            .lowLatencyWireless,
            .wifiLAN,
        ])
        #expect(attempts.map(\.transportKind) == [
            .udp,
            .udp,
            .udp,
            .udp,
            .udp,
            .udp,
            .tcp,
            .tcp,
            .tcp,
            .tcp,
            .tcp,
        ])
        #expect(attempts.filter { $0.routeTier == .wifiLAN }.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.filter { $0.routeTier != .wifiLAN }.allSatisfy { $0.isPeerToPeerPreferred })
    }

    @MainActor
    @Test("Client ranks APNI Bonjour interface before Ethernet")
    func controlSessionAttemptsRankAPNIBeforeEthernet() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61130))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61131))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61132))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "en3", type: .wiredEthernet, index: 10),
                LoomDiscoveredInterface(name: "apni0", type: .other, index: 9),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wired,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )
        let apniSnapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["apni0"],
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

        let apniUDPIndex = try #require(attempts.firstIndex {
            $0.transportKind == .udp && $0.proximityInterfaceKind == .applePrivateNCM
        })
        let wiredUDPIndex = try #require(attempts.firstIndex {
            $0.transportKind == .udp && $0.proximityInterfaceKind == .wiredEthernet
        })
        let apniTCPIndex = try #require(attempts.firstIndex {
            $0.transportKind == .tcp && $0.proximityInterfaceKind == .applePrivateNCM
        })
        let wiredTCPIndex = try #require(attempts.firstIndex {
            $0.transportKind == .tcp && $0.proximityInterfaceKind == .wiredEthernet
        })

        #expect(apniUDPIndex < wiredUDPIndex)
        #expect(apniTCPIndex < wiredTCPIndex)
        #expect(attempts[apniUDPIndex].acceptsProximityPath(apniSnapshot))
        #expect(attempts[apniTCPIndex].acceptsProximityPath(apniSnapshot))
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Wi-Fi preference keeps LLW ahead of Wi-Fi while demoting AWDL")
    func wifiPreferenceKeepsLowLatencyWirelessAheadOfWiFiWhileDemotingAwdl() {
        let service = MirageClientService(deviceName: "Test Device")

        #expect(
            service.controlSessionRouteRank(for: .lowLatencyWireless) <
                service.controlSessionRouteRank(for: .mixedEthernetSameLAN)
        )

        service.preferWiFiBeforeAwdlProximity = true
        #expect(
            service.controlSessionRouteRank(for: .mixedEthernetSameLAN) <
                service.controlSessionRouteRank(for: .wifiLAN)
        )
        #expect(
            service.controlSessionRouteRank(for: .lowLatencyWireless) <
                service.controlSessionRouteRank(for: .wifiLAN)
        )
        #expect(
            service.controlSessionRouteRank(for: .wifiLAN) <
                service.controlSessionRouteRank(for: .awdl)
        )
    }

    @MainActor
    @Test("Client keeps LLW attempts before Wi-Fi while demoting AWDL")
    func controlSessionAttemptsKeepLowLatencyWirelessBeforeWiFiWhileDemotingAwdl() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
            .applePrivateNCM,
            .bridge,
            .lowLatencyWireless,
            .wifiLAN,
            .awdl,
            .applePrivateNCM,
            .bridge,
            .lowLatencyWireless,
            .wifiLAN,
        ])
        #expect(attempts.filter { $0.routeTier == .wifiLAN }.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.filter { $0.routeTier != .wifiLAN }.allSatisfy { $0.isPeerToPeerPreferred })
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Wi-Fi preference chooses retained LAN address before fresh AWDL address")
    func wifiPreferenceChoosesRetainedLANAddressBeforeFreshAwdlAddress() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61110))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61111))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61112))
        let awdlAddress = try #require(IPv6Address("fe80::54d2:dfff:fe24:a4ea%awdl0"))
        let wifiAddress = try #require(IPv4Address("192.168.50.164"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.discoveryProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv6(awdlAddress),
                .ipv4(wifiAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
                LoomDiscoveredInterface(name: "en0", type: .wifi, index: 8),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferWiFiBeforeAwdlProximity = true
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )
        let expectedWiFiEndpoint: NWEndpoint = .hostPort(host: .ipv4(wifiAddress), port: udpPort)

        #expect(attempts[0].endpoint.debugDescription == expectedWiFiEndpoint.debugDescription)
        #expect(attempts[0].routeTier == .wifiLAN)
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[1].routeTier == .awdl)
        #expect(attempts[1].isPeerToPeerPreferred)
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Wi-Fi preference retries remembered direct endpoint before AWDL-only Bonjour result")
    func wifiPreferenceRetriesRememberedDirectEndpointBeforeAwdlOnlyBonjourResult() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61113))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61114))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61115))
        let awdlAddress = try #require(IPv6Address("fe80::54d2:dfff:fe24:a4ea%awdl0"))
        let rememberedAddress = try #require(IPv4Address("192.168.50.164"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.discoveryProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv6(awdlAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "awdl0", type: .other, index: 12),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferWiFiBeforeAwdlProximity = true
        service.rememberDirectEndpointHost(
            .hostPort(host: .ipv4(rememberedAddress), port: udpPort),
            for: deviceID
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )
        let expectedRememberedEndpoint: NWEndpoint = .hostPort(host: .ipv4(rememberedAddress), port: udpPort)

        #expect(attempts[0].endpoint.debugDescription == expectedRememberedEndpoint.debugDescription)
        #expect(attempts[0].routeTier == .wifiLAN)
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[1].routeTier == .awdl)
        #expect(attempts[1].isPeerToPeerPreferred)
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Client keeps wired UDP before AWDL while TCP stays last")
    func controlSessionAttemptsKeepWiredUDPBeforeAwdlWhileTCPStaysLast() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
            .sameWiredEthernet,
            .awdl,
            .sameWiredEthernet,
        ])
        #expect(proximityAttempts.filter {
            $0.routeTier == .sameWiredEthernet
        }.allSatisfy { $0.proximityInterfaceNames == ["en3"] })
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Client ranks LLW before mixed Ethernet same LAN by default")
    func controlSessionAttemptsRankLowLatencyWirelessBeforeMixedEthernetSameLANByDefault() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61046))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61047))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61048))
        let awdlAddress = try #require(IPv6Address("fe80::2%awdl0"))
        let llwAddress = try #require(IPv6Address("fe80::3%llw0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                .ipv6(llwAddress),
                .ipv6(awdlAddress),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
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
            .lowLatencyWireless,
            .mixedEthernetSameLAN,
            .awdl,
            .lowLatencyWireless,
            .mixedEthernetSameLAN,
        ])
        #expect(attempts.filter {
            $0.routeTier == .mixedEthernetSameLAN
        }.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.filter {
            $0.routeTier != .mixedEthernetSameLAN
        }.allSatisfy { $0.isPeerToPeerPreferred })
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Client keeps concrete wired UDP before AWDL without subnet metadata")
    func controlSessionAttemptsKeepConcreteWiredUDPBeforeAwdlWithoutSubnetIntersection() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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

        #expect(proximityAttempts.map(\.routeTier) == [
            .sameWiredEthernet,
            .awdl,
            .sameWiredEthernet,
        ])
        let wiredProximityAttempts = proximityAttempts.filter { $0.routeTier == .sameWiredEthernet }
        #expect(wiredProximityAttempts.allSatisfy { $0.proximityInterfaceNames == ["en3"] })
        #expect(wiredProximityAttempts.allSatisfy { $0.proximityInterfaceKind == .wiredEthernet })
        #expect(wiredProximityAttempts.allSatisfy { $0.requiredInterfaceType == .wiredEthernet })
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Client keeps normal LAN fallback from using wired tier without subnet intersection")
    func controlSessionFallbackDoesNotUseWiredTierWithoutSubnetIntersection() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61058))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61059))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61060))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
            ],
            discoveredInterfaces: []
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

        #expect(!attempts.contains { $0.routeTier == .sameWiredEthernet })
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.map(\.routeTier) == [
            .wifiLAN, .wifiLAN,
        ])
    }

    @MainActor
    @Test("Explicit VPN route skips local candidates and starts UDP first")
    func explicitVPNRouteSkipsLocalCandidatesAndStartsUDPFirst() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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

        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.map(\.candidateKind) == [.overlay, .overlay])
        #expect(attempts.map(\.routeTier) == [.vpn, .vpn])
        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
        #expect(service.controlSessionInitialConnectTimeout(for: attempts[0]) == .seconds(5))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[0]) == .seconds(45))
    }

    @MainActor
    @Test("Bonjour-visible VPN route uses overlay fallback without synthetic LLW")
    func bonjourVisibleVPNRouteUsesOverlayFallbackWithoutSyntheticLLW() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61052))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61053))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61054))
        let overlayAddress = try #require(IPv4Address("100.65.199.51"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.connection-origin": "remote",
                ]
            ),
            resolvedAddresses: [
                .ipv4(overlayAddress),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .vpn,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )
        let expectedOverlayEndpoint: NWEndpoint = .hostPort(
            host: .ipv4(overlayAddress),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(attempts.allSatisfy { $0.candidateKind == .overlay })
        #expect(attempts.allSatisfy { $0.routeTier == .vpn })
        #expect(attempts[0].endpoint.debugDescription == expectedOverlayEndpoint.debugDescription)
        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
    }

    @MainActor
    @Test("Client tries scoped AWDL address after resolved IP fallback")
    func controlSessionAttemptsPreferResolvedAddressFallbackBeforeScopedAwdl() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
        let expectedFallbackUDPEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )
        let expectedFallbackTCPEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: tcpPort
        )

        #expect(attempts.count == 3)
        #expect(attempts.map(\.transportKind) == [.udp, .udp, .tcp])
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].endpoint.debugDescription == expectedFallbackUDPEndpoint.debugDescription)
        #expect(attempts[1].isPeerToPeerPreferred)
        #expect(attempts[1].endpoint.debugDescription == expectedAwdlUDPEndpoint.debugDescription)
        #expect(!attempts[2].isPeerToPeerPreferred)
        #expect(attempts[2].endpoint.debugDescription == expectedFallbackTCPEndpoint.debugDescription)
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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

        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { !$0.isPeerToPeerPreferred })
        #expect(!attempts.contains { $0.routeTier == .awdl })
        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
    @Test("Active AWDL route suppression does not filter low-latency wireless endpoints")
    func activeAwdlRouteSuppressionDoesNotFilterLowLatencyWirelessEndpoints() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61058))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61059))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61060))
        let llwAddress = try #require(IPv6Address("fe80::6%llw0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                .ipv6(llwAddress),
                .ipv4(#require(IPv4Address("192.168.1.50"))),
            ],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.suppressAwdlProximityRoute(
            for: host,
            interfaceNames: ["llw0"],
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
        #expect(attempts.contains { $0.routeTier == .lowLatencyWireless })
        let llwAttempts = attempts.filter { $0.routeTier == .lowLatencyWireless }
        #expect(llwAttempts.allSatisfy { $0.isPeerToPeerPreferred })
        #expect(llwAttempts.map(\.transportKind) == [.udp, .tcp])
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Forced LLW route accepts low-latency wireless endpoints")
    func forcedLowLatencyWirelessRouteAcceptsLowLatencyWirelessEndpoints() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61061))
        let llwAddress = try #require(IPv6Address("fe80::7%llw0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [.ipv6(llwAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.debugRouteOverride = MirageDebugRouteOverride(
            transportKind: .udp,
            interfaceKind: .llw
        )
        let attempts = service.controlSessionAttempts(
            for: host,
            localNetwork: .init(
                currentPathKind: .wifi,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: []
            )
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].routeTier == .lowLatencyWireless)
        #expect(attempts[0].isPeerToPeerPreferred)
        #expect(attempts[0].proximityInterfaceNames == ["llw0"])
    }

    @MainActor
    @Test("Forced AWDL route does not claim low-latency wireless endpoints")
    func forcedAwdlRouteDoesNotClaimLowLatencyWirelessEndpoints() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61062))
        let llwAddress = try #require(IPv6Address("fe80::8%llw0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [.ipv6(llwAddress)],
            discoveredInterfaces: [
                LoomDiscoveredInterface(name: "llw0", type: .other, index: 13),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.debugRouteOverride = MirageDebugRouteOverride(
            transportKind: .udp,
            interfaceKind: .awdl
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
    @Test("Client orders scoped proximity addresses by interface priority")
    func controlSessionAttemptsOrderScopedProximityAddressesByInterfacePriority() throws {
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
    @Test("AWDL attempts keep short timeout when reached as fallback")
    func awdlAttemptsUseShortTimeoutWhenReachedAsFallback() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61032))
        let awdlAddress = try #require(IPv6Address("fe80::6%awdl0"))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(service.controlSessionConnectTimeout(for: attempts[0]) == .seconds(5))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[0]) == .seconds(20))
        #expect(attempts[1].isPeerToPeerPreferred)
        #expect(service.controlSessionConnectTimeout(for: attempts[1]) == .seconds(2))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[1]) == .seconds(6))
        #expect(!attempts[2].isPeerToPeerPreferred)
        #expect(service.controlSessionConnectTimeout(for: attempts[2]) == .seconds(30))
        #expect(service.absoluteControlSessionConnectTimeout(for: attempts[2]) == .seconds(30))
        expectTCPCompatibilityFallbacksAfterUDP(attempts)
    }

    @MainActor
    @Test("Client skips LLW probe for Bonjour host without proximity evidence")
    func controlSessionAttemptsSkipLLWProbeWithoutProximityEvidence() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61025))
        let host = try LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
                protocolVersion: Int(MirageKit.controlProtocolVersion),
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
        let anpiSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
        let wifiSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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

    @Test("Generic proximity validation accepts only proximity-like paths")
    func genericProximityPathValidationRequiresProximityPath() {
        let attempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: "altair.local", port: 61040),
            transportKind: .udp,
            candidateKind: .local,
            requiredInterfaceType: .other,
            isPeerToPeerPreferred: true
        )
        let llwSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
        let wiredSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
        let wifiSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
        let overlaySnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
        let genericOtherSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
