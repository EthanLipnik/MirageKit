//
//  ClientConnectionOverlayEndpointPlanningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Loom
import Network
import Testing
import MirageKit

extension ClientConnectionEndpointPlanningTests {
    @MainActor
    @Test("Client classifies remote-access single-label hosts as overlay")
    func controlSessionAttemptsClassifyRemoteAccessSingleLabelHostsAsOverlay() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61031))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61032))
        let host = LoomPeer(
            id: UUID(),
            name: "Vega",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("Vega"), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: UUID(),
                hostName: "Vega",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.vpn-access": "1",
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferredNetworkType = .wifi
        let attempts = service.controlSessionAttempts(for: host)

        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
        #expect(attempts.allSatisfy { $0.candidateKind == .overlay })
        #expect(attempts.allSatisfy { $0.requiredInterfaceType == nil })
    }

    @MainActor
    @Test("Client classifies remote-access ULA hosts as overlay")
    func controlSessionAttemptsClassifyRemoteAccessULAHostsAsOverlay() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61033))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61034))
        let ulaAddress = try #require(IPv6Address("fd12:3456:789a::50"))
        let host = LoomPeer(
            id: UUID(),
            name: "Vega",
            deviceType: .mac,
            endpoint: .hostPort(host: .ipv6(ulaAddress), port: tcpPort),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: UUID(),
                hostName: "Vega",
                directTransports: [
                    LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
                    LoomDirectTransportAdvertisement(transportKind: .tcp, port: tcpPort.rawValue),
                ],
                metadata: [
                    "mirage.vpn-access": "1",
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.preferredNetworkType = .wifi
        let attempts = service.controlSessionAttempts(for: host)

        #expect(attempts.map(\.transportKind) == [.udp, .tcp])
        #expect(attempts.allSatisfy { $0.candidateKind == .overlay })
        #expect(attempts.allSatisfy { $0.requiredInterfaceType == nil })
    }

    @MainActor
    @Test("Client does not reuse remembered overlay address ahead of Bonjour hostname")
    func controlSessionAttemptsDoNotReuseRememberedOverlayAheadOfBonjourHostname() throws {
        let deviceID = UUID()
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61020))
        let overlayAddress = try #require(IPv4Address("100.65.199.51"))
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
                ],
                metadata: [
                    "mirage.vpn-access": "1",
                ]
            )
        )

        let service = MirageClientService(deviceName: "Test Device")
        service.rememberedDirectEndpointHostByDeviceID[deviceID] = .ipv4(overlayAddress)
        let attempts = service.controlSessionAttempts(for: host)
        let udpAttempt = try #require(attempts.first { $0.transportKind == .udp })
        let expectedUDPEndpoint: NWEndpoint = .hostPort(
            host: NWEndpoint.Host("altair.local"),
            port: udpPort
        )

        #expect(udpAttempt.endpoint.debugDescription == expectedUDPEndpoint.debugDescription)
        #expect(udpAttempt.candidateKind == .local)
    }
}
