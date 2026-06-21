//
//  ClientConnectionEndpointPlanningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Loom
import Network
import Testing

@Suite("Client Connection Endpoint Planning")
struct ClientConnectionEndpointPlanningTests {
    @MainActor
    @Test("Client control sessions prefer UDP before falling back to reliable transports")
    func controlSessionAttemptsPreferUDPThenTCP() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61001))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61002))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
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
    @Test("Client demotes recently failed endpoint among equivalent UDP candidates")
    func controlSessionAttemptCooldownDemotesEquivalentUDPCandidate() throws {
        let firstPort = try #require(NWEndpoint.Port(rawValue: 61003))
        let secondPort = try #require(NWEndpoint.Port(rawValue: 61004))
        let firstAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("192.168.1.50"), port: firstPort),
            transportKind: .udp,
            candidateKind: .local,
            routeTier: .wifiLAN,
            endpointSource: "resolved-local-address",
            requiredInterfaceType: nil
        )
        let secondAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("192.168.1.51"), port: secondPort),
            transportKind: .udp,
            candidateKind: .local,
            routeTier: .wifiLAN,
            endpointSource: "resolved-local-address",
            requiredInterfaceType: nil
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.coolDownControlSessionAttempt(firstAttempt, reason: "timeout")
        let orderedAttempts = service.orderedControlSessionAttempts([
            firstAttempt,
            secondAttempt,
        ])

        #expect(orderedAttempts.map(\.endpoint.debugDescription) == [
            secondAttempt.endpoint.debugDescription,
            firstAttempt.endpoint.debugDescription,
        ])
    }

    @MainActor
    @Test("Client keeps TCP after cooled UDP routes")
    func controlSessionAttemptCooldownKeepsTCPAfterUDPFallbacks() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61005))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61006))
        let fallbackPort = try #require(NWEndpoint.Port(rawValue: 61007))
        let cooledUDPAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("192.168.1.50"), port: udpPort),
            transportKind: .udp,
            candidateKind: .local,
            routeTier: .wifiLAN,
            endpointSource: "resolved-local-address",
            requiredInterfaceType: nil
        )
        let sameRouteTCPAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("192.168.1.50"), port: tcpPort),
            transportKind: .tcp,
            candidateKind: .local,
            routeTier: .wifiLAN,
            endpointSource: "resolved-local-address",
            requiredInterfaceType: nil
        )
        let lowerRouteUDPAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("203.0.113.10"), port: fallbackPort),
            transportKind: .udp,
            candidateKind: .local,
            routeTier: .other,
            endpointSource: "public-address",
            requiredInterfaceType: nil
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.coolDownControlSessionAttempt(cooledUDPAttempt, reason: "manual connection restart")
        let orderedAttempts = service.orderedControlSessionAttempts([
            cooledUDPAttempt,
            sameRouteTCPAttempt,
            lowerRouteUDPAttempt,
        ])

        #expect(orderedAttempts.map(\.endpoint.debugDescription) == [
            lowerRouteUDPAttempt.endpoint.debugDescription,
            cooledUDPAttempt.endpoint.debugDescription,
            sameRouteTCPAttempt.endpoint.debugDescription,
        ])
    }

    @MainActor
    @Test("Control session diagnostics include attempt ID and TCP fallback marker")
    func controlSessionDiagnosticsIncludeAttemptIDAndTCPFallbackMarker() throws {
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61006))
        let tcpAttempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("192.168.1.50"), port: tcpPort),
            transportKind: .tcp,
            candidateKind: .local,
            routeTier: .wifiLAN,
            endpointSource: "resolved-local-address",
            requiredInterfaceType: nil
        )
        let connectionAttemptID = try #require(UUID(uuidString: "4DF97645-633E-4D7B-987C-6F0E40B7D295"))

        let service = MirageClientService(deviceName: "Test Device")
        service.recordControlSessionAttemptStarted(tcpAttempt, connectionAttemptID: connectionAttemptID)

        let summary = try #require(service.recentControlSessionAttemptSummaries.last)
        #expect(summary.connectionAttemptID == "4df97645-633e-4d7b-987c-6f0e40b7d295")
        #expect(summary.supportSummaryLine.contains("attempt=4df97645-633e-4d7b-987c-6f0e40b7d295"))
        #expect(summary.supportSummaryLine.contains("compatibilityFallback=tcp"))
    }

    @MainActor
    @Test("Overlay control sessions prefer UDP before TCP")
    func overlayControlSessionAttemptsPreferUDPBeforeTCP() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61011))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61012))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61013))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.tail0000.ts.net"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.vpn-access": "1",
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)

        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
        #expect(attempts.allSatisfy { $0.candidateKind == .overlay })
        #expect(attempts.allSatisfy { $0.requiredInterface == nil })
        #expect(attempts.allSatisfy { $0.requiredInterfaceType == nil })
    }

    @MainActor
    @Test("Client derives Bonjour UDP host from peer name when advertisement hostName is missing")
    func controlSessionAttemptsDeriveBonjourHostFromPeerName() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61006))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61007))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("Altair.local"),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client reuses remembered direct endpoint hosts when Bonjour is no longer resolvable")
    func controlSessionAttemptsPreferRememberedDirectEndpointHost() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61008))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61009))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "Altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.rememberedDirectEndpointHostByDeviceID[deviceID] = NWEndpoint.Host("192.168.50.20")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("192.168.50.20"),
            port: udpPort
        )
        let expectedTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("192.168.50.20"),
            port: tcpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
        #expect(attempts[1].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Overlay peers use overlay endpoint hosts and advertised transport ports")
    func controlSessionAttemptsPreferOverlayEndpointHostAndPorts() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 65139))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 57210))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 57211))
        let host = LoomPeer(
            id: UUID(),
            name: "Vega",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("100.65.199.51"), port: udpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: UUID(),
                hostName: "Vega",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.65.199.51"),
            port: udpPort
        )
        let expectedTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.65.199.51"),
            port: tcpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[0].candidateKind == .overlay)
        #expect(attempts[0].requiredInterfaceType == nil)
        #expect(attempts[1].transportKind == .tcp)
        #expect(attempts[1].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
        #expect(attempts[1].candidateKind == .overlay)
        #expect(attempts[1].requiredInterfaceType == nil)
    }

    @MainActor
    @Test("Client keeps Bonjour-resolved IP addresses as normal fallback without proximity evidence")
    func controlSessionAttemptsPreferResolvedAddresses() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61020))
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
            resolvedAddresses: [.ipv4(#require(IPv4Address("192.168.1.50")))]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let fallbackAttempt = try #require(
            attempts.first { $0.transportKind == .udp && !$0.isPeerToPeerPreferred }
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(fallbackAttempt.endpoint.debugDescription == expectedEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client does not prefer scope-less link-local IPv6 endpoints for direct control sessions")
    func controlSessionAttemptsAvoidScopeLessLinkLocalIPv6Endpoints() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61023))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61024))
        let linkLocalAddress = try #require(IPv6Address("fe80::1866:72ff:fe1a:1bf0"))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: .ipv6(linkLocalAddress), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [.ipv6(linkLocalAddress)]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
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
        #expect(!attempts.contains { $0.endpoint.debugDescription.contains("fe80") })
    }

    @MainActor
    @Test("Client accepts scoped link-local IPv6 endpoints for direct control sessions")
    func controlSessionAttemptsAcceptScopedLinkLocalIPv6Endpoints() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61025))
        let scopedLinkLocalAddress = try #require(IPv6Address("fe80::1866:72ff:fe1a:1bf0%lo0"))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.protocolVersion),
                deviceID: deviceID,
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [.ipv6(scopedLinkLocalAddress)]
        )

        let service = MirageClientService(
            deviceName: "Test Device",
            loomConfiguration: LoomNetworkConfiguration(enablePeerToPeer: false)
        )
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: .ipv6(scopedLinkLocalAddress),
            port: udpPort
        )
        let scopedAttempt = try #require(
            attempts.first { $0.endpoint.debugDescription == expectedUDPEndpoint.debugDescription }
        )

        #expect(scopedAttempt.transportKind == .udp)
        #expect(scopedAttempt.candidateKind == .local)
        #expect(!scopedAttempt.isPeerToPeerPreferred)
        #expect(!MirageClientService.isScopeLessLinkLocalIPv6Address(.ipv6(scopedLinkLocalAddress)))
    }

    @MainActor
    @Test("Client prefers local addresses over overlay addresses from Bonjour resolution")
    func controlSessionAttemptsPreferLocalOverOverlayResolvedAddresses() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61021))
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
                .ipv4(#require(IPv4Address("100.65.199.51"))),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let udpAttempt = try #require(
            attempts.first { $0.transportKind == .udp && !$0.isPeerToPeerPreferred }
        )
        let expectedEndpoint: NWEndpoint = try .hostPort(
            host: .ipv4(#require(IPv4Address("192.168.1.50"))),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(!attempts[0].isPeerToPeerPreferred)
        #expect(udpAttempt.endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client uses local resolved addresses for TCP before overlay endpoint")
    func controlSessionAttemptsPreferLocalResolvedAddressesForReliableTransport() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61022))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61023))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61024))
        let localAddress = try #require(IPv4Address("192.168.50.164"))
        let overlayAddress = try #require(IPv4Address("100.65.199.51"))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: .ipv4(overlayAddress), port: tcpPort),
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
                    "mirage.vpn-access": "1",
                ]
            ),
            resolvedAddresses: [
                .ipv4(localAddress),
                .ipv4(overlayAddress),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let tcpAttempt = try #require(attempts.first { $0.transportKind == .tcp })
        let udpAttempt = try #require(attempts.first { $0.transportKind == .udp })

        let expectedTCPEndpoint: NWEndpoint = .hostPort(host: .ipv4(localAddress), port: tcpPort)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(host: .ipv4(localAddress), port: udpPort)

        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
        #expect(tcpAttempt.endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
        #expect(udpAttempt.endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client treats local resolved addresses as local even when remote access is advertised")
    func controlSessionAttemptsClassifyLocalResolvedAddressesAsLocalWhenRemoteAccessIsAdvertised() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61021))
        let localAddress = try #require(IPv4Address("192.168.50.164"))
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
                ],
                metadata: [
                    "mirage.vpn-access": "1",
                ]
            ),
            resolvedAddresses: [
                .ipv4(localAddress),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferredNetworkType = .wifi
        let attempts = service.controlSessionAttempts(for: host)
        let udpAttempt = try #require(
            attempts.first { $0.transportKind == .udp && !$0.isPeerToPeerPreferred }
        )

        #expect(udpAttempt.candidateKind == .local)
        #expect(udpAttempt.requiredInterfaceType == .wifi)
    }

}
