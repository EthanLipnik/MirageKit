//
//  ClientLoomControlPlaneTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Loom
import Network
import Testing

#if os(macOS)
@Suite("Client Loom Control Plane", .serialized)
struct ClientLoomControlPlaneTests {
    @MainActor
    @Test("Loom-backed control channel carries bootstrap and follow-up control traffic")
    func loomBackedControlChannelCarriesPostBootstrapTraffic() async throws {
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
        let clientReceiver = ControlMessageReceiver(channel: clientControl)
        let serverReceiver = ControlMessageReceiver(channel: serverControl)
        do {
            let bootstrapRequest = MirageSessionBootstrapRequest(
                protocolVersion: Int(MirageKit.protocolVersion),
                requestedFeatures: mirageSupportedFeatures
            )
            try await clientControl.send(.sessionBootstrapRequest, content: bootstrapRequest)

            let receivedBootstrapEnvelope = try await serverReceiver.next()
            #expect(receivedBootstrapEnvelope.type == .sessionBootstrapRequest)
            let receivedBootstrapRequest = try receivedBootstrapEnvelope.decode(MirageSessionBootstrapRequest.self)
            #expect(receivedBootstrapRequest.protocolVersion == bootstrapRequest.protocolVersion)
            #expect(receivedBootstrapRequest.requestedFeatures == bootstrapRequest.requestedFeatures)

            let bootstrapResponse = MirageSessionBootstrapResponse(
                accepted: true,
                hostID: UUID(),
                hostName: "Loopback Host",
                selectedFeatures: mirageSupportedFeatures,
                mediaEncryptionEnabled: true,
                udpRegistrationToken: Data(repeating: 0xAB, count: MirageMediaSecurity.registrationTokenLength)
            )
            try await serverControl.send(.sessionBootstrapResponse, content: bootstrapResponse)

            let receivedBootstrapResponseEnvelope = try await clientReceiver.next()
            #expect(receivedBootstrapResponseEnvelope.type == .sessionBootstrapResponse)
            let receivedBootstrapResponse = try receivedBootstrapResponseEnvelope.decode(MirageSessionBootstrapResponse.self)
            #expect(receivedBootstrapResponse.accepted == true)
            #expect(receivedBootstrapResponse.hostName == "Loopback Host")

            let appListRequest = AppListRequestMessage(
                forceRefresh: true,
                priorityBundleIdentifiers: ["com.apple.Safari"],
                requestID: UUID()
            )
            try await clientControl.send(.appListRequest, content: appListRequest)

            let appListRequestID: UUID = try await {
                let receivedAppListRequestEnvelope = try await serverReceiver.next()
                #expect(receivedAppListRequestEnvelope.type == .appListRequest)
                let receivedAppListRequest = try receivedAppListRequestEnvelope.decode(AppListRequestMessage.self)
                #expect(receivedAppListRequest.forceRefresh == true)
                #expect(receivedAppListRequest.priorityBundleIdentifiers == ["com.apple.Safari"])
                return receivedAppListRequest.requestID
            }()

            let appListResponse = AppListMessage(
                requestID: appListRequestID,
                apps: [
                    MirageInstalledApp(
                        bundleIdentifier: "com.apple.Safari",
                        name: "Safari",
                        path: "/Applications/Safari.app"
                    ),
                ]
            )
            try await serverControl.send(.appList, content: appListResponse)

            try await {
                let receivedAppListEnvelope = try await clientReceiver.next()
                #expect(receivedAppListEnvelope.type == .appList)
                let receivedAppList = try receivedAppListEnvelope.decode(AppListMessage.self)
                #expect(receivedAppList.requestID == appListResponse.requestID)
                #expect(receivedAppList.apps.count == 1)
                #expect(receivedAppList.apps.first?.bundleIdentifier == "com.apple.Safari")
            }()

            try await clientControl.send(ControlMessage(type: .ping))
            let receivedPing = try await serverReceiver.next()
            #expect(receivedPing.type == .ping)

            try await serverControl.send(ControlMessage(type: .pong))
            let receivedPong = try await clientReceiver.next()
            #expect(receivedPong.type == .pong)

            #expect(await pair.client.state == .ready)
            #expect(await pair.server.state == .ready)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Client control send helpers write onto the Loom control stream")
    func clientControlSendHelpersUseLoomControlChannel() async throws {
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
        let serverReceiver = ControlMessageReceiver(channel: serverControl)
        do {
            let service = MirageClientService(deviceName: "Loopback Client")
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Loopback Host")

            let request = AppListRequestMessage(
                forceRefresh: true,
                forceIconReset: true,
                priorityBundleIdentifiers: ["com.apple.Terminal"],
                requestID: UUID()
            )
            try await service.sendControlMessage(.appListRequest, content: request)

            let receivedRequestEnvelope = try await serverReceiver.next()
            #expect(receivedRequestEnvelope.type == .appListRequest)
            let receivedRequest = try receivedRequestEnvelope.decode(AppListRequestMessage.self)
            #expect(receivedRequest.forceRefresh == true)
            #expect(receivedRequest.forceIconReset == true)
            #expect(receivedRequest.priorityBundleIdentifiers == ["com.apple.Terminal"])

            #expect(service.sendControlMessageBestEffort(ControlMessage(type: .ping)) == true)
            let receivedPing = try await serverReceiver.next()
            #expect(receivedPing.type == .ping)

            let endpoint = try #require(await service.currentControlRemoteEndpoint())
            let sessionRemoteEndpoint = await pair.client.remoteEndpoint
            #expect(endpoint == sessionRemoteEndpoint)
            let pathSnapshot = try #require(await service.currentControlPathSnapshot())
            #expect(pathSnapshot.remoteEndpoint == endpoint)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Concurrent control sends remain intact on the Loom control stream")
    func concurrentControlSendsRemainIntact() async throws {
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
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        let expectedRequestID = UUID()
        let expectedIconData = Data(repeating: 0xA5, count: 256 * 1024)
        let expectedStatus = HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: false,
            channel: .release,
            automationMode: .metadataOnly,
            installDisposition: .idle,
            lastBlockReason: nil,
            lastInstallResultCode: nil,
            currentVersion: "1.0.0",
            availableVersion: nil,
            availableVersionTitle: nil,
            releaseNotesSummary: nil,
            releaseNotesBody: nil,
            releaseNotesFormat: nil,
            lastCheckedAtMs: nil
        )

        let receiveTask = Task<[ControlMessage], Error> {
            var messages: [ControlMessage] = []
            messages.reserveCapacity(3)
            for _ in 0..<3 {
                messages.append(try await serverReceiver.next())
            }
            return messages
        }

        do {
            async let sendIcon: Void = clientControl.send(
                .hostHardwareIcon,
                content: HostHardwareIconMessage(
                    pngData: expectedIconData,
                    iconName: "test-hardware-icon",
                    hardwareModelIdentifier: "Mac16,5",
                    hardwareMachineFamily: "macBook"
                )
            )
            async let sendAppList: Void = clientControl.send(
                .appListRequest,
                content: AppListRequestMessage(
                    forceRefresh: true,
                    forceIconReset: true,
                    priorityBundleIdentifiers: ["com.apple.Safari"],
                    requestID: expectedRequestID
                )
            )
            async let sendStatus: Void = clientControl.send(
                .hostSoftwareUpdateStatus,
                content: expectedStatus
            )

            _ = try await (sendIcon, sendAppList, sendStatus)

            try await {
                let receivedMessages = try await receiveTask.value
                #expect(receivedMessages.count == 3)

                let iconEnvelope = try #require(receivedMessages.first { $0.type == .hostHardwareIcon })
                let iconMessage = try iconEnvelope.decode(HostHardwareIconMessage.self)
                #expect(iconMessage.pngData == expectedIconData)
                #expect(iconMessage.iconName == "test-hardware-icon")

                let appListEnvelope = try #require(receivedMessages.first { $0.type == .appListRequest })
                let appListMessage = try appListEnvelope.decode(AppListRequestMessage.self)
                #expect(appListMessage.requestID == expectedRequestID)
                #expect(appListMessage.forceIconReset == true)

                let statusEnvelope = try #require(receivedMessages.first { $0.type == .hostSoftwareUpdateStatus })
                let statusMessage = try statusEnvelope.decode(HostSoftwareUpdateStatusMessage.self)
                #expect(statusMessage.currentVersion == expectedStatus.currentVersion)
                #expect(statusMessage.channel == expectedStatus.channel)
            }()
        } catch {
            receiveTask.cancel()
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("TCP fallback sessions keep control traffic and labeled media streams coherent")
    func tcpFallbackSessionKeepsControlAndMediaTrafficCoherent() async throws {
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
        let serverReceiver = ControlMessageReceiver(channel: serverControl)
        let incomingStreamsTask = Task<[LoomMultiplexedStream], Never> {
            var streams: [LoomMultiplexedStream] = []
            let observer = await pair.server.makeIncomingStreamObserver()
            for await stream in observer {
                guard stream.label == "control/42" || stream.label == "video/42" else { continue }
                streams.append(stream)
                if streams.count == 2 {
                    return streams
                }
            }
            return streams
        }

        let controlStream = try await pair.client.openStream(label: "control/42")
        let videoStream = try await pair.client.openStream(label: "video/42")
        let incomingStreams = await incomingStreamsTask.value
        #expect(incomingStreams.count == 2)
        let serverVideoStream = try #require(incomingStreams.first { $0.label == "video/42" })

        let expectedVideoPayloads = (0..<6).map { Data("video-\($0)".utf8) }
        let receivedVideoTask = Task {
            await collectPayloads(from: serverVideoStream, count: expectedVideoPayloads.count)
        }
        do {
            for index in expectedVideoPayloads.indices {
                try await clientControl.send(ControlMessage(type: .ping))
                let receivedPing = try await serverReceiver.next()
                #expect(receivedPing.type == .ping)

                try await controlStream.send(Data("control-\(index)".utf8))
                try await videoStream.sendUnreliable(expectedVideoPayloads[index])
            }

            try await controlStream.close()
            try await videoStream.close()

            #expect(await receivedVideoTask.value == expectedVideoPayloads)
            #expect(await pair.client.state == .ready)
            #expect(await pair.server.state == .ready)
        } catch {
            try? await controlStream.close()
            try? await videoStream.close()
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
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
        service: "com.ethanlipnik.mirage.tests.control-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.mirage.tests.control-server.\(UUID().uuidString)",
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
    let serverTrustProvider = AllowAllTrustProvider()

    return LoopbackControlPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        serverTrustProvider: serverTrustProvider,
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

private func collectPayloads(
    from stream: LoomMultiplexedStream,
    count: Int
) async -> [Data] {
    var payloads: [Data] = []
    for await payload in stream.incomingBytes {
        payloads.append(payload)
        if payloads.count == count {
            return payloads
        }
    }
    return payloads
}

private final class ControlMessageReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedResults: [Result<ControlMessage, Error>] = []
    private var waitingContinuations: [CheckedContinuation<Result<ControlMessage, Error>, Never>] = []
    private var receiveTask: Task<Void, Never> = Task {}

    init(channel: MirageControlChannel) {
        receiveTask.cancel()
        receiveTask = Task {
            for await payload in channel.incomingBytes {
                do {
                    let (message, consumed) = try requireParsedControlMessage(from: payload)
                    #expect(consumed == payload.count)
                    self.enqueue(.success(message))
                } catch {
                    self.enqueue(.failure(error))
                    return
                }
            }

            self.enqueue(
                .failure(MirageError.protocolError("Control stream closed before receiving a Mirage control message"))
            )
        }
    }

    deinit {
        receiveTask.cancel()
    }

    func next() async throws -> ControlMessage {
        if let result = takeBufferedResult() {
            return try result.get()
        }

        let result = await withCheckedContinuation { continuation in
            lock.lock()
            if let bufferedResult = bufferedResults.first {
                bufferedResults.removeFirst()
                lock.unlock()
                continuation.resume(returning: bufferedResult)
                return
            }
            waitingContinuations.append(continuation)
            lock.unlock()
        }
        return try result.get()
    }

    private func enqueue(_ result: Result<ControlMessage, Error>) {
        lock.lock()
        if let continuation = waitingContinuations.first {
            waitingContinuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        bufferedResults.append(result)
        lock.unlock()
    }

    private func takeBufferedResult() -> Result<ControlMessage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let result = bufferedResults.first else {
            return nil
        }
        bufferedResults.removeFirst()
        return result
    }
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
