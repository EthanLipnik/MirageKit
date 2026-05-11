//
//  MirageClientService+ControlSending.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Loom-backed post-bootstrap control-plane send helpers.
//

import Foundation
import Loom
import MirageKit
import Network

@MainActor
extension MirageClientService {
    func requireConnectedControlChannel() throws -> MirageControlChannel {
        guard case .connected = connectionState,
              let controlChannel else {
            throw MirageError.protocolError("Not connected")
        }
        return controlChannel
    }

    func sendControlMessage(_ message: ControlMessage) async throws {
        try await requireConnectedControlChannel().send(message)
    }

    func sendControlMessage(_ type: ControlMessageType, content: some Encodable) async throws {
        let message = try ControlMessage(type: type, content: content)
        try await sendControlMessage(message)
    }

    func sendSerializedControlMessage(_ data: Data) async throws {
        try await requireConnectedControlChannel().sendSerialized(data)
    }

    func sendControlMessageBestEffort(_ message: ControlMessage) {
        guard case .connected = connectionState,
              let controlChannel else {
            return
        }
        controlChannel.sendBestEffort(message)
    }

    func sendControlMessageBestEffort(_ type: ControlMessageType) {
        sendControlMessageBestEffort(ControlMessage(type: type))
    }

    func sendControlMessageBestEffort(_ type: ControlMessageType, content: some Encodable) {
        guard let message = try? ControlMessage(type: type, content: content) else {
            return
        }
        sendControlMessageBestEffort(message)
    }

    func currentControlRemoteEndpoint() async -> NWEndpoint? {
        if let loomSession {
            return await loomSession.remoteEndpoint
        }
        return connectedHost?.endpoint
    }

    func currentControlPathSnapshot() async -> LoomSessionNetworkPathSnapshot? {
        guard let loomSession else { return nil }
        return await loomSession.pathSnapshot
    }

    /// Refresh the cached control-path classification from the active Loom session.
    /// This is useful immediately before automatic stream startup so the first
    /// request does not rely on an `.unknown` path while the observer is still warming up.
    public func refreshCurrentControlPathKind() async {
        guard let snapshot = await currentControlPathSnapshot() else {
            return
        }
        let classifiedSnapshot = MirageNetworkPathClassifier.classify(snapshot)
        handleControlPathUpdate(classifiedSnapshot)
    }
}
