//
//  MirageClientService+ConnectionAttemptState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import Loom
import Network

@MainActor
extension MirageClientService {
    func rememberDirectEndpointHost(_ endpoint: NWEndpoint?, for deviceID: UUID) {
        guard let endpoint else { return }
        guard case let .hostPort(host, _) = endpoint else { return }
        guard shouldPreferEndpointHostForDirectConnection(host) else { return }
        rememberedDirectEndpointHostByDeviceID[deviceID] = host
    }

    func beginConnectAttempt() -> UUID {
        let attemptID = UUID()
        currentConnectAttemptID = attemptID
        return attemptID
    }

    func finishConnectAttempt(_ attemptID: UUID) {
        guard currentConnectAttemptID == attemptID else { return }
        currentConnectAttemptID = nil
    }

    func invalidateCurrentConnectAttempt() {
        currentConnectAttemptID = nil
    }

    func isCurrentConnectAttempt(_ attemptID: UUID) -> Bool {
        currentConnectAttemptID == attemptID
    }

    func throwIfConnectAttemptIsStale(_ attemptID: UUID) throws {
        guard isCurrentConnectAttempt(attemptID) else {
            throw CancellationError()
        }
    }

    @discardableResult
    func registerPendingConnectTask(
        _ task: Task<LoomAuthenticatedSession, Error>,
        attemptID: UUID
    ) -> UUID {
        let taskID = UUID()
        var tasks = pendingConnectTasksByAttemptID[attemptID, default: [:]]
        tasks[taskID] = task
        pendingConnectTasksByAttemptID[attemptID] = tasks
        return taskID
    }

    func cancelPendingConnectTask(attemptID: UUID? = nil) {
        if let attemptID {
            let tasks = pendingConnectTasksByAttemptID.removeValue(forKey: attemptID) ?? [:]
            tasks.values.forEach { $0.cancel() }
            return
        }

        let tasks = pendingConnectTasksByAttemptID.values.flatMap(\.values)
        pendingConnectTasksByAttemptID.removeAll()
        tasks.forEach { $0.cancel() }
    }

    func clearPendingConnectTaskIfNeeded(
        taskID: UUID,
        attemptID: UUID
    ) {
        guard var tasks = pendingConnectTasksByAttemptID[attemptID] else { return }
        tasks.removeValue(forKey: taskID)
        if tasks.isEmpty {
            pendingConnectTasksByAttemptID.removeValue(forKey: attemptID)
        } else {
            pendingConnectTasksByAttemptID[attemptID] = tasks
        }
    }

    func clearPendingConnectTasksIfNeeded(for attemptID: UUID) {
        pendingConnectTasksByAttemptID.removeValue(forKey: attemptID)
    }

    func performBootstrap(
        over controlChannel: MirageControlChannel,
        provisionalHost: LoomPeer,
        requestTakeoverIfBusy: Bool = false,
        protocolVersionOverride: Int? = nil
    ) async throws {
        connectionState = .handshaking(host: provisionalHost.name)
        MirageConnectivity.MirageInstrumentation.record(.clientHelloSent)
        MirageLogger.client("Sending Mirage bootstrap request to \(provisionalHost.name)")
        try await controlChannel.send(
            .sessionBootstrapRequest,
            content: makeBootstrapRequest(
                requestTakeoverIfBusy: requestTakeoverIfBusy,
                protocolVersionOverride: protocolVersionOverride
            )
        )

        MirageLogger.client("Waiting for Mirage bootstrap response from \(provisionalHost.name)")
        let responseMessage = try await receiveSingleControlMessage(
            from: controlChannel.incomingBytes,
            timeout: bootstrapResponseTimeout,
            timeoutMessage: "Timed out waiting for host bootstrap response from \(provisionalHost.name)"
        )
        guard responseMessage.type == .sessionBootstrapResponse else {
            throw MirageCore.MirageError.protocolError("Expected Mirage session bootstrap response")
        }
        MirageLogger.client("Received Mirage bootstrap response from \(provisionalHost.name)")
        let response = try responseMessage.decode(MirageWire.MirageSessionBootstrapResponse.self)
        try await handleBootstrapResponse(
            response,
            provisionalHost: provisionalHost,
            session: controlChannel.session
        )
    }

    func receiveSingleControlMessage(
        from stream: AsyncStream<Data>,
        timeout: Duration? = nil,
        timeoutMessage: String? = nil
    ) async throws -> MirageWire.ControlMessage {
        if let timeout,
           let timeoutMessage {
            return try await withThrowingTaskGroup(of: MirageWire.ControlMessage.self) { group in
                group.addTask {
                    try await self.receiveSingleControlMessageUnbounded(from: stream)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MirageCore.MirageError.protocolError(timeoutMessage)
                }

                let message = try await group.next() ?? {
                    throw MirageCore.MirageError.protocolError("Control message receive ended unexpectedly")
                }()
                group.cancelAll()
                return message
            }
        }

        return try await receiveSingleControlMessageUnbounded(from: stream)
    }

    func receiveSingleControlMessageUnbounded(
        from stream: AsyncStream<Data>
    ) async throws -> MirageWire.ControlMessage {
        var buffer = Data()

        for await chunk in stream {
            guard !chunk.isEmpty else { continue }
            buffer.append(chunk)

            switch MirageWire.ControlMessage.deserialize(from: buffer) {
            case let .success(message, consumed):
                if consumed < buffer.count {
                    receiveBuffer = Data(buffer.dropFirst(consumed))
                }
                return message
            case .needMoreData:
                continue
            case let .invalidFrame(reason):
                throw MirageCore.MirageError.protocolError("Invalid control frame: \(reason)")
            }
        }

        throw MirageCore.MirageError.protocolError("Control stream closed before receiving bootstrap response")
    }

    func installControlSessionObservers(_ session: LoomAuthenticatedSession) {
        controlSessionStateObserverTask?.cancel()
        let serviceBox = WeakSendableBox(self)
        controlSessionStateObserverTask = Task.detached(priority: .userInitiated) { [session, serviceBox] in
            let observer = await session.makeStateObserver()
            for await state in observer {
                guard !Task.isCancelled else { break }
                guard let service = serviceBox.value else { break }
                guard await service.loomSession?.id == session.id else { break }
                MirageLogger.client("Control session state observed: session=\(session.id.uuidString) state=\(state)")
                switch state {
                case let .failed(reason):
                    await service.handleDisconnect(
                        reason: reason,
                        state: .error(reason),
                        notifyDelegate: service.hasCompletedBootstrap
                    )
                case .cancelled:
                    await service.handleDisconnect(
                        reason: "Connection cancelled",
                        state: .disconnected,
                        notifyDelegate: service.hasCompletedBootstrap
                    )
                default:
                    continue
                }
                break
            }
        }

        controlSessionPathObserverTask?.cancel()
        controlSessionPathObserverTask = Task.detached(priority: .userInitiated) { [session, serviceBox] in
            let observer = await session.makePathObserver()
            for await pathSnapshot in observer {
                guard !Task.isCancelled else { break }
                guard let service = serviceBox.value else { break }
                guard await service.loomSession?.id == session.id else { break }
                let snapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(pathSnapshot)
                MirageLogger.client(
                    "Control path updated: session=\(session.id.uuidString) \(snapshot.signature)"
                )
                await service.handleControlPathUpdate(snapshot)
            }
        }
    }
}
