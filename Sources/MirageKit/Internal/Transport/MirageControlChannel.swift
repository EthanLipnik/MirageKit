//
//  MirageControlChannel.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

import Foundation
import Loom

// The Mirage control stream carries mixed metadata and lifecycle traffic.
// Serialize writes so host-side response tasks cannot overlap sends on the
// same multiplexed stream during connection setup or app-selection refreshes.
private actor MirageControlChannelSendLane {
    private var tail: Task<Void, Never>?
    private var latestOperationID: UInt64 = 0

    func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        latestOperationID &+= 1
        let operationID = latestOperationID

        let task = Task<Void, Error> {
            _ = await previous?.result
            try Task.checkCancellation()
            try await operation()
        }

        tail = Task {
            _ = await task.result
        }

        do {
            try await task.value
        } catch {
            if latestOperationID == operationID {
                tail = nil
            }
            throw error
        }

        if latestOperationID == operationID {
            tail = nil
        }
    }
}

package final class MirageControlChannel: @unchecked Sendable {
    package static let label = "com.ethanlipnik.mirage.control.v1"

    package let session: LoomAuthenticatedSession
    package let stream: LoomMultiplexedStream
    private let sendLane = MirageControlChannelSendLane()

    package init(session: LoomAuthenticatedSession, stream: LoomMultiplexedStream) {
        self.session = session
        self.stream = stream
    }

    package var incomingBytes: AsyncStream<Data> {
        stream.incomingBytes
    }

    package func send(_ message: ControlMessage) async throws {
        try await sendSerialized(message.serialize())
    }

    package func send(_ type: ControlMessageType, content: some Encodable) async throws {
        try await send(ControlMessage(type: type, content: content))
    }

    package func sendSerialized(_ data: Data) async throws {
        try await sendLane.perform { [stream] in
            try await stream.send(data)
        }
    }

    package func sendBestEffort(_ message: ControlMessage) {
        Task {
            try? await self.sendSerialized(message.serialize())
        }
    }

    package func sendBestEffort(_ type: ControlMessageType, content: some Encodable) {
        guard let message = try? ControlMessage(type: type, content: content) else { return }
        sendBestEffort(message)
    }

    package func sendSerializedBestEffort(_ data: Data) {
        Task {
            try? await self.sendSerialized(data)
        }
    }

    package func cancel() async {
        try? await stream.close()
        await session.cancel()
    }

    package static func open(on session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        let stream = try await session.openStream(label: Self.label)
        return MirageControlChannel(session: session, stream: stream)
    }

    package static func accept(from session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        for await stream in session.incomingStreams {
            if stream.label == Self.label {
                return MirageControlChannel(session: session, stream: stream)
            }
        }
        throw MirageError.protocolError("Authenticated Loom session closed before Mirage control stream opened")
    }
}
