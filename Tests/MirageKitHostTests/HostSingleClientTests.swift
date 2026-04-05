//
//  HostSingleClientTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Single-client enforcement for host connections.
//

@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Host Single-Client")
struct HostSingleClientTests {
    @Test("Single-client slot is exclusive")
    @MainActor
    func singleClientSlotIsExclusive() {
        let host = MirageHostService()

        let sessionIDA = UUID()
        let sessionIDB = UUID()

        #expect(host.reserveSingleClientSlot(for: sessionIDA))
        #expect(host.singleClientSessionID == sessionIDA)
        #expect(host.allowsNewClientConnections == false)
        #expect(host.currentPeerAdvertisement.mirageAcceptingConnections == false)
        #expect(!host.reserveSingleClientSlot(for: sessionIDB))

        host.releaseSingleClientSlot(for: sessionIDA)
        #expect(host.singleClientSessionID == nil)
        #expect(host.allowsNewClientConnections == true)
        #expect(host.currentPeerAdvertisement.mirageAcceptingConnections == true)
        #expect(host.reserveSingleClientSlot(for: sessionIDB))
    }

    @Test("Stale slot reservation expires and reopens availability")
    @MainActor
    func staleSlotReservationExpiresAndReopensAvailability() {
        let host = MirageHostService()
        let staleSessionID = UUID()
        let replacementSessionID = UUID()

        #expect(host.reserveSingleClientSlot(for: staleSessionID))
        host.singleClientReservationStartedAt = CFAbsoluteTimeGetCurrent() - (host.connectionApprovalTimeoutSeconds + 1)

        host.updateAdvertisedConnectionAvailability()

        #expect(host.singleClientSessionID == nil)
        #expect(host.allowsNewClientConnections)
        #expect(host.currentPeerAdvertisement.mirageAcceptingConnections)
        #expect(host.reserveSingleClientSlot(for: replacementSessionID))
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
