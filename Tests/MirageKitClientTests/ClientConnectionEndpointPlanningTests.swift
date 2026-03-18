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
    @Test("Bonjour service endpoints return the raw service endpoint")
    func bonjourServiceEndpointsReturnRawService() throws {
        let service = MirageClientService(deviceName: "Test Device")
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
            transportKind: .tcp
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].source == .bonjourService)

        switch attempts[0].endpoint {
        case .service:
            break
        default:
            Issue.record("Expected the control endpoint attempt to keep the raw Bonjour service.")
        }
    }
}
