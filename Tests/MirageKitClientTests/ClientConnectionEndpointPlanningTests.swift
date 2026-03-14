//
//  ClientConnectionEndpointPlanningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Network
import Testing

@Suite("Client Connection Endpoint Planning")
struct ClientConnectionEndpointPlanningTests {
    @MainActor
    @Test("Bonjour service endpoints prefer the raw service before one resolved fallback")
    func bonjourServiceEndpointsPreferRawServiceBeforeResolvedFallback() throws {
        let service = MirageClientService(deviceName: "Test Device")
        let resolvedPort = try #require(NWEndpoint.Port(rawValue: 54_094))
        let host = LoomPeer(
            id: UUID(),
            name: "Ethan's Mac Studio",
            deviceType: .mac,
            endpoint: .service(
                name: "Ethan's Mac Studio",
                type: MirageKit.serviceType,
                domain: "local.",
                interface: nil
            ),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(Loom.protocolVersion),
                deviceID: UUID(),
                identityKeyID: "host-key",
                deviceType: .mac
            )
        )

        let attempts = service.controlEndpointAttempts(
            for: host,
            transportKind: .tcp,
            resolvedBonjourEndpoint: .hostPort(host: NWEndpoint.Host("192.168.1.25"), port: resolvedPort)
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].source == .bonjourService)
        #expect(attempts[1].source == .resolvedBonjourService)

        switch attempts[0].endpoint {
        case .service:
            break
        default:
            Issue.record("Expected the first control endpoint attempt to keep the raw Bonjour service.")
        }

        switch attempts[1].endpoint {
        case let .hostPort(host, port):
            #expect(host.debugDescription == "192.168.1.25")
            #expect(port == resolvedPort)
        default:
            Issue.record("Expected the resolved Bonjour fallback to use a numeric host/port endpoint.")
        }
    }
}
