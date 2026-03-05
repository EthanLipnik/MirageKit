//
//  MirageInputEventSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Dedicated input-event send path that stays off MainActor.
//

import Foundation
import MirageKit
import Network

final class MirageInputEventSender: @unchecked Sendable {
    private let sendQueue = DispatchQueue(label: "com.mirage.client.input-send", qos: .userInteractive)
    private let connectionLock = NSLock()
    private var controlConnection: NWConnection?

    func updateConnection(_ connection: NWConnection?) {
        connectionLock.lock()
        controlConnection = connection
        connectionLock.unlock()
    }

    func sendInput(_ event: MirageInputEvent, streamID: StreamID) async throws {
        let data = try makeInputMessageData(event: event, streamID: streamID)
        let connection = try currentConnectionOrThrow()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    func sendInputFireAndForget(_ event: MirageInputEvent, streamID: StreamID) {
        let data: Data
        do {
            data = try makeInputMessageData(event: event, streamID: streamID)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to encode input: ")
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let connection = self.currentConnection() else { return }
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func makeInputMessageData(event: MirageInputEvent, streamID: StreamID) throws -> Data {
        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, payload: inputMessage.serializePayload())
        return message.serialize()
    }

    private func currentConnection() -> NWConnection? {
        connectionLock.lock()
        let connection = controlConnection
        connectionLock.unlock()
        return connection
    }

    private func currentConnectionOrThrow() throws -> NWConnection {
        guard let connection = currentConnection() else {
            throw MirageError.protocolError("Not connected")
        }
        return connection
    }
}
