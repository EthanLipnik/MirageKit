//
//  HostControlChannelTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

#if os(macOS)
@testable import MirageKit
import Foundation
import Loom
import Network
import Testing
import MirageConnectivity
import MirageCore
import MirageWire

func nextControlMessage(
    from channel: MirageControlChannel,
    timeout: Duration = .seconds(1),
    matching predicate: @escaping @Sendable (MirageWire.ControlMessage) -> Bool = { _ in true }
) async throws -> MirageWire.ControlMessage {
    try await withThrowingTaskGroup(of: MirageWire.ControlMessage.self) { group in
        group.addTask {
            var buffer = Data()
            for await chunk in channel.incomingBytes {
                guard !chunk.isEmpty else { continue }
                buffer.append(chunk)

                parseLoop:
                while true {
                    switch MirageWire.ControlMessage.deserialize(from: buffer) {
                    case let .success(message, consumed):
                        buffer.removeFirst(consumed)
                        if predicate(message) {
                            return message
                        }
                    case .needMoreData:
                        break parseLoop
                    case let .invalidFrame(reason):
                        throw MirageCore.MirageError.protocolError("Invalid control frame: \(reason)")
                    }
                }
            }

            throw MirageCore.MirageError.protocolError("Control stream closed before receiving a Mirage control message")
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MirageCore.MirageError.timeout
        }

        guard let message = try await group.next() else {
            throw MirageCore.MirageError.timeout
        }
        group.cancelAll()
        return message
    }
}

struct LoopbackControlPair {
    let listener: NWListener
    let clientIdentityManager: LoomIdentityManager
    let serverIdentityManager: LoomIdentityManager
    let serverTrustProvider: AllowAllTrustProvider
    let clientHello: LoomSessionHelloRequest
    let serverHello: LoomSessionHelloRequest
    let client: LoomAuthenticatedSession
    let server: LoomAuthenticatedSession

    func startAuthenticatedSessions() async throws {
        async let clientContext = client.start(
            localHello: clientHello,
            identityManager: clientIdentityManager
        )
        async let serverContext = server.start(
            localHello: serverHello,
            identityManager: serverIdentityManager,
            trustProvider: serverTrustProvider
        )
        _ = try await (clientContext, serverContext)
    }

    func stop() async {
        listener.cancel()
        await client.cancel()
        await server.cancel()
    }
}

@MainActor
func makeLoopbackControlPair() async throws -> LoopbackControlPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.mirage.tests.host-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.mirage.tests.host-server.\(UUID().uuidString)",
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
        connection: .tcp(clientConnection),
        role: .initiator
    )
    let server = LoomAuthenticatedSession(
        connection: .tcp(serverConnection),
        role: .receiver
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
final class AllowAllTrustProvider: LoomTrustProvider {
    func evaluateTrust(for _: LoomPeerIdentity) async -> LoomTrustDecision {
        .trusted
    }

    func evaluateTrustOutcome(for _: LoomPeerIdentity) async -> LoomTrustEvaluation {
        LoomTrustEvaluation(decision: .trusted, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to _: LoomPeerIdentity) async throws {}

    func revokeTrust(for _: UUID) async throws {}
}
#endif
