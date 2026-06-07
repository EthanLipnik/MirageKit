//
//  HostDisconnectNotificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/17/26.
//
//  Host-initiated disconnect notification behavior.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Foundation
import MirageConnectivity
import Testing
import MirageWire

@Suite("Host Disconnect Notification", .serialized)
struct HostDisconnectNotificationTests {
    @MainActor
    @Test("Host-initiated disconnect sends a client-visible disconnect notice")
    func hostInitiatedDisconnectSendsClientNotice() async throws {
        let pair = try await makeLoopbackControlPair()

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value

        let host = MirageHostService(hostName: "Disconnect Test Host")
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Test iPad",
            deviceType: .iPad,
            connectedAt: Date(),
            identityKeyID: "test-client-key"
        )
        let sessionID = pair.server.id
        let hostClientContext = ClientContext(
            sessionID: sessionID,
            client: client,
            controlChannel: serverControl,
            transferEngine: MirageTransferEngine(session: pair.server),
            pathSnapshot: nil
        )
        host.connectedClients = [client]
        host.clientsBySessionID[sessionID] = hostClientContext
        host.clientsByID[client.id] = hostClientContext
        host.singleClientSessionID = sessionID

        let receiveTask = Task {
            try await nextControlMessage(from: clientControl)
        }
        let disconnectTask = Task {
            await host.disconnectClient(client, sessionID: sessionID)
        }

        do {
            let message = try await receiveTask.value
            #expect(message.type == .disconnect)
            let disconnect = try message.decode(MirageWire.DisconnectMessage.self)
            #expect(disconnect.reason == .userRequested)

            await disconnectTask.value
            #expect(host.connectedClients.isEmpty)
            #expect(host.clientsBySessionID.isEmpty)
            #expect(host.clientsByID[client.id] == nil)
            #expect(host.singleClientSessionID == nil)
        } catch {
            receiveTask.cancel()
            disconnectTask.cancel()
            await serverControl.cancel()
            await clientControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }
}
#endif
