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
@testable import MirageKitClient
@testable import MirageKitHost
import Foundation
import Loom
import MirageConnectivity
import Network
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

    @MainActor
    @Test("Trusted busy takeover disconnects old client and connects replacement")
    func trustedBusyTakeoverDisconnectsOldClientAndConnectsReplacement() async throws {
        let oldPair = try await makeLoopbackControlPair()
        try await oldPair.startAuthenticatedSessions()

        let oldServerControlTask = Task {
            try await MirageControlChannel.accept(from: oldPair.server)
        }
        let oldClientControl = try await MirageControlChannel.open(on: oldPair.client)
        let oldServerControl = try await oldServerControlTask.value

        let hostID = UUID()
        let host = MirageHostService(hostName: "Busy Takeover Host", deviceID: hostID)
        let oldClient = MirageConnectedClient(
            id: oldPair.clientHello.deviceID,
            name: "Old iPad",
            deviceType: .iPad,
            connectedAt: Date(),
            identityKeyID: "old-client-key"
        )
        let oldSessionID = oldPair.server.id
        let oldClientContext = ClientContext(
            sessionID: oldSessionID,
            client: oldClient,
            controlChannel: oldServerControl,
            transferEngine: MirageTransferEngine(session: oldPair.server),
            pathSnapshot: nil
        )
        host.connectedClients = [oldClient]
        host.clientsBySessionID[oldSessionID] = oldClientContext
        host.clientsByID[oldClient.id] = oldClientContext
        host.singleClientSessionID = oldSessionID

        let newPair = try await makeLoopbackControlPair()
        try await newPair.startAuthenticatedSessions()
        host.identityManager = newPair.serverIdentityManager
        let clientService = MirageClientService(deviceName: "Replacement iPad")
        clientService.identityManager = newPair.clientIdentityManager
        let hostPeer = LoomPeer(
            id: hostID,
            name: "Busy Takeover Host",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: 1),
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageWireProtocol.currentControlVersion),
                deviceID: hostID,
                deviceType: .mac
            )
        )

        let hostTask = Task {
            await host.handleIncomingSession(newPair.server)
        }

        do {
            try await clientService.connect(
                withEstablishedSession: newPair.client,
                host: hostPeer,
                requestTakeoverIfBusy: true
            )
            await hostTask.value

            #expect(host.connectedClients.count == 1)
            #expect(host.connectedClients.first?.id == newPair.clientHello.deviceID)
            #expect(host.clientsByID[oldClient.id] == nil)
            #expect(host.clientsByID[newPair.clientHello.deviceID]?.sessionID == newPair.server.id)
            #expect(host.clientsBySessionID[newPair.server.id]?.client.id == newPair.clientHello.deviceID)
            #expect(host.singleClientSessionID == newPair.server.id)
            #expect(clientService.connectionState == .connected(host: "Busy Takeover Host"))
        } catch {
            hostTask.cancel()
            await oldClientControl.cancel()
            await oldServerControl.cancel()
            await oldPair.stop()
            await newPair.stop()
            throw error
        }

        await clientService.cancelConnectionImmediately()
        await oldClientControl.cancel()
        await oldServerControl.cancel()
        await oldPair.stop()
        await newPair.stop()
    }
}
#endif
