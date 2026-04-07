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

    @MainActor
    @Test("Client control sessions prefer UDP before falling back to TCP")
    func controlSessionAttemptsPreferUdpThenTcp() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_001))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61_002))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
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
        let expectedUdpEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: udpPort
        )
        let expectedTcpEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: tcpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUdpEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
        #expect(attempts[1].endpoint.debugDescription == expectedTcpEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client qualifies short Bonjour names for UDP control attempts")
    func controlSessionAttemptsQualifyShortBonjourNames() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_004))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61_005))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: UUID(),
                hostName: "Altair",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUdpEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("Altair.local"),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUdpEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client derives Bonjour UDP host from peer name when advertisement hostName is missing")
    func controlSessionAttemptsDeriveBonjourHostFromPeerName() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_006))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61_007))
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: UUID(),
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUdpEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("Altair.local"),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUdpEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .tcp)
    }

    @MainActor
    @Test("Client reuses remembered direct endpoint hosts when Bonjour is no longer resolvable")
    func controlSessionAttemptsPreferRememberedDirectEndpointHost() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_008))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61_009))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: deviceID,
                hostName: "Altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.rememberedDirectEndpointHostByDeviceID[deviceID] = NWEndpoint.Host("100.64.10.2")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.64.10.2"),
            port: udpPort
        )
        let expectedTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.64.10.2"),
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
        let udpPort = try #require(NWEndpoint.Port(rawValue: 65_139))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 57_210))
        let host = LoomPeer(
            id: UUID(),
            name: "Ethan's Mac Studio",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("100.65.199.51"), port: udpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: UUID(),
                hostName: "Ethan's Mac Studio",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .quic, port: quicPort.rawValue),
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.65.199.51"),
            port: udpPort
        )
        let expectedQUICEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.65.199.51"),
            port: quicPort
        )
        let expectedTCPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("100.65.199.51"),
            port: udpPort
        )

        #expect(attempts.count == 3)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(attempts[1].transportKind == .quic)
        #expect(attempts[1].endpoint.debugDescription == expectedQUICEndpoint.debugDescription)
        #expect(attempts[2].transportKind == .tcp)
        #expect(attempts[2].endpoint.debugDescription == expectedTCPEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client control session failures classify retryable transport errors")
    func controlSessionFailureClassificationRecognizesRetryableTransportErrors() throws {
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ENETUNREACH))
            ) == .transportLoss
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ECONNREFUSED))
            ) == .connectionRefused
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.EADDRNOTAVAIL))
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(
                    NWError.dns(-65_554)
                )
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(
                    LoomConnectionFailure(
                        reason: .timedOut,
                        detail: "Reliable UDP transport timed out awaiting acknowledgement."
                    )
                )
            ) == .timeout
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(MirageError.timeout) == .timeout
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.protocolError("Failed to resolve zephir-m3.local: nodename nor servname provided, or not known")
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError("Failed to resolve zephir-m3.local: nodename nor servname provided, or not known")
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError(
                    "Pre-bootstrap udp control session failed for zephir-m3 endpoint=zephir-m3.local:51024 interface=wifi classification=other error=Protocol error: Failed to resolve zephir-m3.local: nodename nor servname provided, or not known"
                )
            ) == .addressUnavailable
        )
    }

    @MainActor
    @Test("Client retries later direct transports for retryable failures")
    func retryPolicyContinuesThroughLaterAdvertisedTransports() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_010))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61_011))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61_012))
        let attempts = [
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: udpPort),
                transportKind: .udp,
                requiredInterfaceType: nil
            ),
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: quicPort),
                transportKind: .quic,
                requiredInterfaceType: nil
            ),
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
                transportKind: .tcp,
                requiredInterfaceType: nil
            ),
        ]

        #expect(
            MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .addressUnavailable,
                attempts: attempts,
                currentAttemptIndex: 0
            )
        )
        #expect(
            MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .timeout,
                attempts: attempts,
                currentAttemptIndex: 1
            )
        )
        #expect(
            !MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .addressUnavailable,
                attempts: attempts,
                currentAttemptIndex: 2
            )
        )
        #expect(
            !MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .other,
                attempts: attempts,
                currentAttemptIndex: 0
            )
        )
    }

    @MainActor
    @Test("Client control session failure reasons include transport, endpoint, and interface context")
    func controlSessionFailureReasonIncludesContext() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 61_003))
        let attempt = MirageClientService.ControlSessionAttempt(
            hostName: "Altair",
            endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: port),
            transportKind: .udp,
            requiredInterfaceType: .wifi
        )

        let reason = MirageClientService.controlSessionFailureReason(
            for: attempt,
            classification: .connectionRefused,
            underlyingError: LoomError.connectionFailed(NWError.posix(.ECONNREFUSED))
        )

        #expect(reason.contains("udp"))
        #expect(reason.contains("Altair"))
        #expect(reason.contains("altair.local"))
        #expect(reason.contains("wifi"))
        #expect(reason.contains("connectionRefused"))
    }

    @MainActor
    @Test("Client diagnoses different Wi-Fi networks for local failures")
    func localNetworkMismatchReasonDiagnosesDifferentWiFiNetworks() {
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: "altair.local", port: 6100),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
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

        #expect(reason?.contains("different Wi-Fi networks") == true)
    }

    @MainActor
    @Test("Client diagnoses different wired networks for local failures")
    func localNetworkMismatchReasonDiagnosesDifferentWiredNetworks() {
        let host = LoomPeer(
            id: UUID(),
            name: "Altair",
            deviceType: .mac,
            endpoint: .hostPort(host: "altair.local", port: 6100),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: UUID(),
                metadata: [
                    "mirage.net.wired": "24:hostwired",
                ]
            )
        )

        let reason = MirageClientService.localNetworkMismatchReason(
            for: host,
            classification: .transportLoss,
            localNetwork: MirageClientService.ControlSessionNetworkDiagnostics(
                currentPathKind: .wired,
                wifiSubnetSignatures: [],
                wiredSubnetSignatures: ["24:clientwired"]
            )
        )

        #expect(reason?.contains("same wired network") == true)
    }

    @MainActor
    @Test("Client uses Bonjour-resolved IP addresses instead of hostname")
    func controlSessionAttemptsPreferResolvedAddresses() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_020))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [.ipv4(IPv4Address("192.168.1.50")!)]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedEndpoint: NWEndpoint = .hostPort(
            host: .ipv4(IPv4Address("192.168.1.50")!),
            port: udpPort
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].transportKind == .udp)
        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client prefers local addresses over overlay addresses from Bonjour resolution")
    func controlSessionAttemptsPreferLocalOverOverlayResolvedAddresses() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_021))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(IPv4Address("192.168.1.50")!),
                .ipv4(IPv4Address("100.65.199.51")!),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedEndpoint: NWEndpoint = .hostPort(
            host: .ipv4(IPv4Address("192.168.1.50")!),
            port: udpPort
        )

        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
    }

    @MainActor
    @Test("Client falls back to overlay resolved address when no local addresses exist")
    func controlSessionAttemptsFallBackToOverlayResolvedAddress() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_022))
        let host = LoomPeer(
            id: deviceID,
            name: "Altair",
            deviceType: .mac,
            endpoint: .service(name: "Altair", type: "_mirage._tcp", domain: "local", interface: nil),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: deviceID,
                hostName: "altair.local",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                ]
            ),
            resolvedAddresses: [
                .ipv4(IPv4Address("100.65.199.51")!),
            ]
        )

        let service = MirageClientService(deviceName: "Test Device")
        let attempts = service.controlSessionAttempts(for: host)
        let expectedEndpoint: NWEndpoint = .hostPort(
            host: .ipv4(IPv4Address("100.65.199.51")!),
            port: udpPort
        )

        #expect(attempts[0].endpoint.debugDescription == expectedEndpoint.debugDescription)
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
                protocolVersion: Int(Loom.protocolVersion),
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
}
