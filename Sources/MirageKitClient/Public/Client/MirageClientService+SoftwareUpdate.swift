//
//  MirageClientService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Client host software update requests and mismatch-trigger handshake.
//

import Foundation
import Network
import MirageKit

@MainActor
public extension MirageClientService {
    /// Requests host software update status from the active host connection.
    /// - Parameter forceRefresh: When true, host refreshes update metadata before replying.
    func requestHostSoftwareUpdateStatus(forceRefresh: Bool = false) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let request = HostSoftwareUpdateStatusRequestMessage(forceRefresh: forceRefresh)
        let message = try ControlMessage(type: .hostSoftwareUpdateStatusRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    /// Requests host software update installation from the active host connection.
    /// - Parameter trigger: Install trigger context used by host authorization logic.
    func requestHostSoftwareUpdateInstall(trigger: HostSoftwareUpdateInstallTrigger = .manual) async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let requestTrigger: HostSoftwareUpdateInstallRequestMessage.Trigger
        switch trigger {
        case .manual:
            requestTrigger = .manual
        case .protocolMismatch:
            requestTrigger = .protocolMismatch
        }

        let request = HostSoftwareUpdateInstallRequestMessage(
            trigger: requestTrigger
        )
        let message = try ControlMessage(type: .hostSoftwareUpdateInstallRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    /// Performs a one-shot mismatch handshake requesting remote host update execution.
    /// This does not modify current client connection state.
    /// - Parameter host: Host endpoint to target for the handshake request.
    /// - Returns: Protocol mismatch metadata including trigger acceptance result.
    func requestHostUpdateViaMismatchHandshake(to host: MirageHost) async throws -> ProtocolMismatchInfo {
        let parameters = controlParameters(for: .tcp)
        let transientConnection = NWConnection(to: host.endpoint, using: parameters)
        defer {
            transientConnection.cancel()
        }

        try await waitForConnectionReady(transientConnection)

        let helloRequest = try makeHelloMessage(requestHostUpdateOnProtocolMismatch: true)
        let helloEnvelope = try ControlMessage(type: .hello, content: helloRequest.hello)
        try await sendControlMessage(helloEnvelope, over: transientConnection)

        let responseMessage = try await receiveSingleControlMessage(over: transientConnection)
        guard responseMessage.type == ControlMessageType.helloResponse else {
            throw MirageError.protocolError("Expected hello response")
        }

        let response = try responseMessage.decode(HelloResponseMessage.self)
        guard response.requestNonce == helloRequest.nonce else {
            throw MirageError.protocolError("Invalid handshake nonce")
        }

        if response.accepted {
            throw MirageError.protocolError("Host accepted session; mismatch update flow unavailable")
        }

        guard let mismatchInfo = protocolMismatchInfo(from: response) else {
            throw MirageError.protocolError(helloRejectionDescription(for: response, mismatchInfo: nil))
        }

        return mismatchInfo
    }
}

private extension MirageClientService {
    func waitForConnectionReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuationBox = ContinuationBox<Void>(continuation)
            connection.stateUpdateHandler = { [continuationBox] state in
                switch state {
                case .ready:
                    continuationBox.resume()
                case let .failed(error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(throwing: MirageError.protocolError("Connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func sendControlMessage(_ message: ControlMessage, over connection: NWConnection) async throws {
        let data = message.serialize()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuationBox = ContinuationBox<Void>(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuationBox.resume(throwing: error)
                } else {
                    continuationBox.resume()
                }
            })
        }
    }

    func receiveSingleControlMessage(over connection: NWConnection) async throws -> ControlMessage {
        var buffer = Data()

        while true {
            let result: (Data?, NWConnection.ContentContext?, Bool, NWError?) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
                    continuation.resume(returning: (data, context, isComplete, error))
                }
            }

            let (data, _, isComplete, error) = result
            if let error {
                throw error
            }

            if let data, !data.isEmpty {
                buffer.append(data)
                if let (message, _) = ControlMessage.deserialize(from: buffer) {
                    return message
                }
            }

            if isComplete {
                throw MirageError.protocolError("Connection closed before hello response")
            }
        }
    }
}
