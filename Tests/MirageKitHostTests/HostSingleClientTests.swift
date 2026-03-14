//
//  HostSingleClientTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Single-client enforcement for host connections.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
import Network

@Suite("Host Single-Client")
struct HostSingleClientTests {
    @Test("Single-client slot is exclusive")
    @MainActor
    func singleClientSlotIsExclusive() {
        let host = MirageHostService()

        let connectionA = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .tcp
        )
        let connectionB = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .tcp
        )

        let connectionIDA = ObjectIdentifier(connectionA)
        let connectionIDB = ObjectIdentifier(connectionB)

        #expect(host.reserveSingleClientSlot(for: connectionIDA))
        #expect(host.singleClientConnectionID == connectionIDA)
        #expect(!host.reserveSingleClientSlot(for: connectionIDB))

        host.releaseSingleClientSlot(for: connectionIDA)
        #expect(host.singleClientConnectionID == nil)
        #expect(host.reserveSingleClientSlot(for: connectionIDB))
    }

    @Test("Reconnect preemption matches same device ID")
    @MainActor
    func reconnectPreemptionMatchesSameDeviceID() {
        let host = MirageHostService()
        let clientID = UUID()

        let existingClient = MirageConnectedClient(
            id: clientID,
            name: "Existing iPad",
            deviceType: .iPad,
            connectedAt: Date(),
            identityKeyID: "existing-key"
        )
        let incomingPeer = LoomPeerIdentity(
            deviceID: clientID,
            name: "Incoming iPad",
            deviceType: .iPad,
            iCloudUserID: nil,
            identityKeyID: "different-key",
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        #expect(host.shouldPreemptExistingClient(existingClient, for: incomingPeer))
    }

    @Test("Reconnect preemption matches same identity key ID")
    @MainActor
    func reconnectPreemptionMatchesIdentityKeyID() {
        let host = MirageHostService()

        let existingClient = MirageConnectedClient(
            id: UUID(),
            name: "Existing Mac",
            deviceType: .mac,
            connectedAt: Date(),
            identityKeyID: "shared-key"
        )
        let incomingPeer = LoomPeerIdentity(
            deviceID: UUID(),
            name: "Incoming Mac",
            deviceType: .mac,
            iCloudUserID: nil,
            identityKeyID: "shared-key",
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        #expect(host.shouldPreemptExistingClient(existingClient, for: incomingPeer))
    }

    @Test("Reconnect preemption ignores unrelated clients")
    @MainActor
    func reconnectPreemptionIgnoresUnrelatedClients() {
        let host = MirageHostService()

        let existingClient = MirageConnectedClient(
            id: UUID(),
            name: "Existing Vision Pro",
            deviceType: .vision,
            connectedAt: Date(),
            identityKeyID: "existing-key"
        )
        let incomingPeer = LoomPeerIdentity(
            deviceID: UUID(),
            name: "Incoming iPad",
            deviceType: .iPad,
            iCloudUserID: nil,
            identityKeyID: "incoming-key",
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        #expect(!host.shouldPreemptExistingClient(existingClient, for: incomingPeer))
    }
}
#endif
