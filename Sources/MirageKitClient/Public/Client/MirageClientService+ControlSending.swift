//
//  MirageClientService+ControlSending.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Loom-backed post-bootstrap control-plane send helpers.
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
import Network

@MainActor
extension MirageClientService {
    /// Returns the active control channel or throws when the client is not connected.
    func requireConnectedControlChannel() throws -> MirageControlChannel {
        guard case .connected = connectionState,
              let controlChannel else {
            throw MirageCore.MirageError.protocolError("Not connected")
        }
        return controlChannel
    }

    /// Sends an already-encoded control message on the connected control channel.
    func sendControlMessage(_ message: MirageWire.ControlMessage) async throws {
        try await requireConnectedControlChannel().send(message)
    }

    /// Encodes and sends a typed control message on the connected control channel.
    func sendControlMessage(_ type: MirageWire.ControlMessageType, content: some Encodable) async throws {
        let message = try MirageWire.ControlMessage(type: type, content: content)
        try await sendControlMessage(message)
    }

    /// Attempts to enqueue a control message without throwing when the control channel is unavailable.
    func sendControlMessageBestEffort(_ message: MirageWire.ControlMessage) -> Bool {
        guard case .connected = connectionState,
              let controlChannel else {
            return false
        }
        controlChannel.sendBestEffort(message)
        return true
    }

    /// Attempts to enqueue an unreliable control message without throwing when the control channel is unavailable.
    func sendControlMessageBestEffortUnreliable(_ message: MirageWire.ControlMessage) -> Bool {
        guard case .connected = connectionState,
              let controlChannel else {
            return false
        }
        controlChannel.sendBestEffortUnreliable(message)
        return true
    }

    /// Encodes and attempts to enqueue a control message without throwing on encode or send failure.
    func sendControlMessageBestEffort(_ type: MirageWire.ControlMessageType, content: some Encodable) -> Bool {
        guard let message = try? MirageWire.ControlMessage(type: type, content: content) else {
            return false
        }
        return sendControlMessageBestEffort(message)
    }

    /// Encodes and attempts to enqueue an unreliable control message without throwing on encode or send failure.
    func sendControlMessageBestEffortUnreliable(_ type: MirageWire.ControlMessageType, content: some Encodable) -> Bool {
        guard let message = try? MirageWire.ControlMessage(type: type, content: content) else {
            return false
        }
        return sendControlMessageBestEffortUnreliable(message)
    }

    /// Enqueues a best-effort control message and intentionally ignores unavailable-channel failures.
    func queueControlMessageBestEffort(_ message: MirageWire.ControlMessage) {
        _ = sendControlMessageBestEffort(message)
    }

    /// Encodes and enqueues a best-effort control message while intentionally ignoring failures.
    func queueControlMessageBestEffort(_ type: MirageWire.ControlMessageType, content: some Encodable) {
        _ = sendControlMessageBestEffort(type, content: content)
    }

    /// Enqueues an unreliable best-effort control message while intentionally ignoring failures.
    func queueControlMessageBestEffortUnreliable(_ type: MirageWire.ControlMessageType, content: some Encodable) {
        _ = sendControlMessageBestEffortUnreliable(type, content: content)
    }

    /// Refresh the cached control-path classification from the active Loom session.
    /// This is useful immediately before automatic stream startup so the first
    /// request does not rely on an `.unknown` path while the observer is still warming up.
    public func refreshCurrentControlPathKind() async -> MirageCore.MirageNetworkPathKind? {
        guard let loomSession,
              let snapshot = await loomSession.pathSnapshot else {
            return currentControlPathKind
        }
        let classifiedSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(snapshot)
        handleControlPathUpdate(classifiedSnapshot)
        return classifiedSnapshot.kind
    }

    /// Refreshes the cached control-path classification and discards the resulting kind.
    public func updateCurrentControlPathKind() async {
        _ = await refreshCurrentControlPathKind()
    }
}
