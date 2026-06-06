//
//  HostStreamRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
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

#if os(macOS)
/// Thread-safe host stream side table for routing input.
final class HostStreamRegistry: @unchecked Sendable {
    private struct State {
        /// Custom-stream input handlers keyed by the stream that owns the handler.
        var customInputHandlers: [StreamID: any MirageCustomStreamInputHandler] = [:]
        /// Active input session IDs mapped to the client that is authorized to use them.
        var activeInputSessionClientIDs: [UUID: UUID] = [:]
    }

    private let state = Locked(State())

    /// Registers the input handler for a custom stream.
    func registerCustomInputHandler(
        streamID: StreamID,
        _ handler: any MirageCustomStreamInputHandler
    ) {
        state.withLock { $0.customInputHandlers[streamID] = handler }
    }

    /// Removes a custom stream input handler when its stream is torn down.
    func unregisterCustomInputHandler(streamID: StreamID) {
        state.withLock { $0.customInputHandlers[streamID] = nil }
    }

    /// Returns the input handler for a custom stream, if one is still registered.
    func customInputHandler(streamID: StreamID) -> (any MirageCustomStreamInputHandler)? {
        state.read { $0.customInputHandlers[streamID] }
    }

    /// Marks an input session as active for one authenticated client.
    func registerInputSession(_ sessionID: UUID, clientID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs[sessionID] = clientID }
    }

    /// Removes an input session after the client stops using it.
    func unregisterInputSession(_ sessionID: UUID) {
        state.withLock { $0.activeInputSessionClientIDs[sessionID] = nil }
    }

    /// Removes every active input session owned by a disconnected client.
    func unregisterInputSessions(for clientID: UUID) {
        state.withLock { mutableState in
            mutableState.activeInputSessionClientIDs = mutableState.activeInputSessionClientIDs.filter {
                $0.value != clientID
            }
        }
    }

    /// Returns whether the session exists and still belongs to the requesting client.
    func isInputSessionActive(_ sessionID: UUID, clientID: UUID) -> Bool {
        state.read { $0.activeInputSessionClientIDs[sessionID] == clientID }
    }
}
#endif
