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

    @discardableResult
    func sendControlMessageBestEffort(_ message: ControlMessage) -> Bool {
        guard case .connected = connectionState,
              let controlChannel else {
            return false
        }
        controlChannel.sendBestEffort(message)
        return true
    }

    @discardableResult
    func sendControlMessageBestEffort(_ type: ControlMessageType, content: some Encodable) -> Bool {
        guard let message = try? ControlMessage(type: type, content: content) else {
            return false
        }
        return sendControlMessageBestEffort(message)
    }

    @discardableResult
    func sendSerializedControlMessageBestEffort(_ data: Data) -> Bool {
        guard case .connected = connectionState,
              let controlChannel else {
            return false
        }
        controlChannel.sendSerializedBestEffort(data)
        return true
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
}
