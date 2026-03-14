//
//  MirageClientService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Client host software update requests and mismatch-trigger handshake.
//

import Foundation
import Loom
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
    func requestHostUpdateViaMismatchHandshake(to host: LoomPeer) async throws -> ProtocolMismatchInfo {
        let session = try await loomNode.connect(
            to: host.endpoint,
            using: .tcp,
            hello: try makeSessionHelloRequest()
        )
        defer {
            Task {
                await session.cancel()
            }
        }

        let controlChannel = try await MirageControlChannel.open(on: session)
        try await controlChannel.send(
            .sessionBootstrapRequest,
            content: makeBootstrapRequest(requestHostUpdateOnProtocolMismatch: true)
        )

        let responseMessage = try await receiveSingleControlMessage(from: controlChannel.incomingBytes)
        guard responseMessage.type == ControlMessageType.sessionBootstrapResponse else {
            throw MirageError.protocolError("Expected session bootstrap response")
        }

        let response = try responseMessage.decode(MirageSessionBootstrapResponse.self)
        if response.accepted {
            throw MirageError.protocolError("Host accepted session; mismatch update flow unavailable")
        }

        guard let mismatchInfo = protocolMismatchInfo(from: response) else {
            throw MirageError.protocolError(bootstrapRejectionDescription(for: response, mismatchInfo: nil))
        }

        return mismatchInfo
    }
}
