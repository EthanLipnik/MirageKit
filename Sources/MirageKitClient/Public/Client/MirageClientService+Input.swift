//
//  MirageClientService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client input event dispatch.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Send an input event to the host with network confirmation.
    func sendInput(_ event: MirageInputEvent, forStream streamID: StreamID) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, content: inputMessage)
        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Send an input event to the host without waiting for network confirmation.
    func sendInputFireAndForget(_ event: MirageInputEvent, forStream streamID: StreamID) {
        guard case .connected = connectionState, let connection else { return }

        do {
            let inputMessage = InputEventMessage(streamID: streamID, event: event)
            let message = try ControlMessage(type: .inputEvent, content: inputMessage)
            let data = message.serialize()
            connection.send(content: data, completion: .idempotent)
        } catch {
            MirageLogger.error(.client, "Failed to send input: \(error)")
        }
    }
}
