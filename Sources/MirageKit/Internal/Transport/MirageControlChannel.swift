//
//  MirageControlChannel.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

import Foundation
import Loom
import Network

package final class MirageControlChannel: @unchecked Sendable {
    package static let label = "com.ethanlipnik.mirage.control.v1"

    package let session: LoomAuthenticatedSession
    package let stream: LoomMultiplexedStream
    package let rawConnection: NWConnection

    package init(
        session: LoomAuthenticatedSession,
        stream: LoomMultiplexedStream,
        rawConnection: NWConnection
    ) {
        self.session = session
        self.stream = stream
        self.rawConnection = rawConnection
    }

    package var incomingBytes: AsyncStream<Data> {
        stream.incomingBytes
    }

    package func send(_ message: ControlMessage) async throws {
        try await stream.send(message.serialize())
    }

    package func send(_ type: ControlMessageType, content: some Encodable) async throws {
        try await send(ControlMessage(type: type, content: content))
    }

    package func sendBestEffort(_ message: ControlMessage) {
        Task {
            try? await self.stream.send(message.serialize())
        }
    }

    package func sendBestEffort(_ type: ControlMessageType, content: some Encodable) {
        guard let message = try? ControlMessage(type: type, content: content) else { return }
        sendBestEffort(message)
    }

    package func cancel() async {
        try? await stream.close()
        await session.cancel()
    }

    package static func open(on session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        let stream = try await session.openStream(label: Self.label)
        let rawConnection = await session.rawSession.connection
        return MirageControlChannel(session: session, stream: stream, rawConnection: rawConnection)
    }

    package static func accept(from session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        let rawConnection = await session.rawSession.connection
        for await stream in session.incomingStreams {
            if stream.label == Self.label {
                return MirageControlChannel(session: session, stream: stream, rawConnection: rawConnection)
            }
        }
        throw MirageError.protocolError("Authenticated Loom session closed before Mirage control stream opened")
    }
}
