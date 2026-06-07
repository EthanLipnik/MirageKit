//
//  MirageControlChannel+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageWire

/// The Mirage control stream carries mixed metadata and lifecycle traffic.
/// Serialize writes so host-side response tasks cannot overlap sends on the
/// same multiplexed stream during connection setup or app-selection refreshes.
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

/// Ordered control-stream wrapper for Mirage lifecycle and metadata messages.
///
/// The channel owns Mirage-level send serialization while the authenticated
/// Loom session owns the underlying stream lifetime.
package final class MirageControlChannel: @unchecked Sendable {
    /// Loom stream label used for Mirage control traffic.
    package static let label = "com.ethanlipnik.mirage.control.v2"

    /// Authenticated Loom session that carries the control stream.
    package let session: LoomAuthenticatedSession
    /// Multiplexed Loom stream carrying serialized control messages.
    package let stream: LoomMultiplexedStream
    private let sendLane = MirageControlChannelSendLane()

    /// Creates a control channel around an accepted or opened Loom stream.
    package init(session: LoomAuthenticatedSession, stream: LoomMultiplexedStream) {
        self.session = session
        self.stream = stream
    }

    /// Incoming serialized control-message bytes from the Loom stream.
    package var incomingBytes: AsyncStream<Data> {
        stream.incomingBytes
    }

    /// Sends a prebuilt control message on the ordered send lane.
    package func send(_ message: MirageWire.ControlMessage) async throws {
        try await sendSerialized(message.serialize())
    }

    /// Encodes and sends a typed control message payload on the ordered send lane.
    package func send(_ type: MirageWire.ControlMessageType, content: some Encodable) async throws {
        try await send(MirageWire.ControlMessage(type: type, content: content))
    }

    /// Sends already-serialized control bytes after prior ordered sends complete.
    package func sendSerialized(_ data: Data) async throws {
        try await sendLane.perform { [stream] in
            try await stream.send(data)
        }
    }

    /// Sends already-serialized control bytes without the reliable send lane.
    package func sendSerializedUnreliable(_ data: Data) async throws {
        try await stream.sendUnreliable(data)
    }

    /// Starts a best-effort ordered send and intentionally ignores failures.
    package func sendBestEffort(_ message: MirageWire.ControlMessage) {
        Task {
            try? await self.sendSerialized(message.serialize())
        }
    }

    /// Starts a best-effort unreliable send and intentionally ignores failures.
    package func sendBestEffortUnreliable(_ message: MirageWire.ControlMessage) {
        Task {
            try? await self.sendSerializedUnreliable(message.serialize())
        }
    }

    /// Starts a best-effort empty control-message send and intentionally ignores failures.
    package func sendBestEffort(_ type: MirageWire.ControlMessageType) {
        sendBestEffort(MirageWire.ControlMessage(type: type))
    }

    /// Closes only the control stream after queued ordered sends complete.
    package func closeStream() async throws {
        // Bootstrap rejection paths need an ordered EOF on the control stream
        // so the peer can read the final response before either side tears the
        // authenticated Loom session down.
        try await sendLane.perform { [stream] in
            try await stream.close()
        }
    }

    /// Cancels the authenticated session that owns this control stream.
    package func cancel() async {
        // A Mirage control channel does not own the lifetime of the underlying
        // Loom stream independently from the session. When the product decides
        // to disconnect, tearing down the authenticated session already closes
        // every multiplexed stream and avoids racing a control-stream close
        // frame against full-session shutdown on both peers. Use closeStream()
        // when the peer is still blocked waiting on a final control response.
        await session.cancel()
    }

    /// Opens a new Mirage control stream on an authenticated Loom session.
    package static func open(on session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        let stream = try await session.openStream(label: Self.label)
        return MirageControlChannel(session: session, stream: stream)
    }

    /// Accepts the next incoming Mirage control stream on an authenticated Loom session.
    package static func accept(from session: LoomAuthenticatedSession) async throws -> MirageControlChannel {
        for await stream in session.incomingStreams {
            if stream.label == label {
                return MirageControlChannel(session: session, stream: stream)
            }
        }
        throw MirageConnectionErrors.authenticatedSessionClosedBeforeControlStreamOpened()
    }
}
