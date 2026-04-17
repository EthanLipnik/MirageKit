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
import Network
import Testing

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
            negotiatedFeatures: mirageSupportedFeatures,
            controlChannel: serverControl,
            remoteEndpoint: nil,
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
            let disconnect = try message.decode(DisconnectMessage.self)
            #expect(disconnect.reason == .userRequested)
            #expect(disconnect.message == "Disconnected by host")

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

private func nextControlMessage(
    from channel: MirageControlChannel,
    timeout: Duration = .seconds(1)
) async throws -> ControlMessage {
    try await withThrowingTaskGroup(of: ControlMessage.self) { group in
        group.addTask {
            var buffer = Data()
            for await chunk in channel.incomingBytes {
                guard !chunk.isEmpty else { continue }
                buffer.append(chunk)

                switch ControlMessage.deserialize(from: buffer) {
                case let .success(message, _):
                    return message
                case .needMoreData:
                    continue
                case let .invalidFrame(reason):
                    throw MirageError.protocolError("Invalid control frame: \(reason)")
                }
            }

            throw MirageError.protocolError("Control stream closed before receiving a Mirage control message")
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MirageError.timeout
        }

        guard let message = try await group.next() else {
            throw MirageError.timeout
        }
        group.cancelAll()
        return message
    }
}

private struct LoopbackControlPair {
    let listener: NWListener
    let clientIdentityManager: LoomIdentityManager
    let serverIdentityManager: LoomIdentityManager
    let serverTrustProvider: AllowAllTrustProvider
    let clientHello: LoomSessionHelloRequest
    let serverHello: LoomSessionHelloRequest
    let client: LoomAuthenticatedSession
    let server: LoomAuthenticatedSession

    func stop() async {
        listener.cancel()
        await client.cancel()
        await server.cancel()
    }
}

@MainActor
private func makeLoopbackControlPair() async throws -> LoopbackControlPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.mirage.tests.host-disconnect-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.mirage.tests.host-disconnect-server.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )

    let listener = try NWListener(using: .tcp, on: .any)
    let acceptedConnection = AsyncBox<NWConnection>()
    let readyPort = AsyncBox<UInt16>()

    listener.newConnectionHandler = { connection in
        Task {
            await acceptedConnection.set(connection)
        }
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue {
            Task {
                await readyPort.set(port)
            }
        }
    }
    listener.start(queue: .global(qos: .userInitiated))

    let port = try #require(await readyPort.take())
    let clientPort = try #require(NWEndpoint.Port(rawValue: port))
    let clientConnection = NWConnection(
        host: "127.0.0.1",
        port: clientPort,
        using: .tcp
    )
    let serverConnection = try #require(await acceptedConnection.take(after: {
        clientConnection.start(queue: .global(qos: .userInitiated))
    }))

    let client = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: clientConnection),
        role: .initiator,
        transportKind: .tcp
    )
    let server = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: serverConnection),
        role: .receiver,
        transportKind: .tcp
    )

    let clientHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Client",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac)
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Server",
        deviceType: .mac,
        advertisement: LoomPeerAdvertisement(deviceType: .mac)
    )

    return LoopbackControlPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: AllowAllTrustProvider(),
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

private actor AsyncBox<Value: Sendable> {
    private var value: Value?
    private var continuations: [CheckedContinuation<Value?, Never>] = []

    func set(_ newValue: Value) {
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: newValue)
            return
        }
        value = newValue
    }

    func take(after action: @escaping @Sendable () -> Void) async -> Value? {
        action()
        return await take()
    }

    func take() async -> Value? {
        if let value {
            self.value = nil
            return value
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

@MainActor
private final class AllowAllTrustProvider: LoomTrustProvider {
    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        .trusted
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {}

    func revokeTrust(for deviceID: UUID) async throws {}
}
#endif
