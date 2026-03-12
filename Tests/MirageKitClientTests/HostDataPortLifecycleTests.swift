//
//  HostDataPortLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//

@testable import MirageKitClient
import Testing

@Suite("Host Data Port Lifecycle")
struct HostDataPortLifecycleTests {
    @MainActor
    @Test("Stopping the UDP socket preserves the negotiated host data port")
    func stopVideoConnectionPreservesNegotiatedDataPort() {
        let service = MirageClientService(deviceName: "Test Device")
        service.hostDataPort = 57_442

        service.stopVideoConnection()

        #expect(service.hostDataPort == 57_442)
    }

    @MainActor
    @Test("Disconnect cleanup clears the negotiated host data port")
    func disconnectCleanupClearsNegotiatedDataPort() async {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Altair")
        service.hostDataPort = 57_442

        await service.handleDisconnect(
            reason: "test",
            state: .disconnected,
            notifyDelegate: false
        )

        #expect(service.hostDataPort == 0)
    }
}
