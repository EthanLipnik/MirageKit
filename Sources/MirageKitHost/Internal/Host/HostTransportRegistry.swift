//
//  HostTransportRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
/// Thread-safe registry for host TCP/UDP data transport sockets.
final class HostTransportRegistry: @unchecked Sendable {
    private struct State {
        var videoByStream: [StreamID: NWConnection] = [:]
        var audioByClientID: [UUID: NWConnection] = [:]
        var qualityByClientID: [UUID: NWConnection] = [:]
    }

    private let state = Locked(State())

    func registerVideoConnection(_ connection: NWConnection, streamID: StreamID) {
        state.withLock { $0.videoByStream[streamID] = connection }
    }

    @discardableResult
    func unregisterVideoConnection(streamID: StreamID) -> NWConnection? {
        state.withLock { $0.videoByStream.removeValue(forKey: streamID) }
    }

    func registerAudioConnection(_ connection: NWConnection, clientID: UUID) {
        state.withLock { $0.audioByClientID[clientID] = connection }
    }

    @discardableResult
    func unregisterAudioConnection(clientID: UUID) -> NWConnection? {
        state.withLock { $0.audioByClientID.removeValue(forKey: clientID) }
    }

    func registerQualityConnection(_ connection: NWConnection, clientID: UUID) {
        state.withLock { $0.qualityByClientID[clientID] = connection }
    }

    @discardableResult
    func unregisterQualityConnection(clientID: UUID) -> NWConnection? {
        state.withLock { $0.qualityByClientID.removeValue(forKey: clientID) }
    }

    @discardableResult
    func unregisterAllConnections(clientID: UUID) -> [NWConnection] {
        state.withLock { state in
            var removed: [NWConnection] = []
            if let audio = state.audioByClientID.removeValue(forKey: clientID) {
                removed.append(audio)
            }
            if let quality = state.qualityByClientID.removeValue(forKey: clientID) {
                removed.append(quality)
            }
            return removed
        }
    }

    func sendVideo(
        streamID: StreamID,
        data: Data,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        guard let connection = state.read({ $0.videoByStream[streamID] }) else {
            onComplete?()
            return
        }

        if let onComplete {
            connection.send(content: data, completion: .contentProcessed { _ in
                onComplete()
            })
        } else {
            connection.send(content: data, completion: .idempotent)
        }
    }

    func sendAudio(clientID: UUID, data: Data) {
        guard let connection = state.read({ $0.audioByClientID[clientID] }) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func sendQuality(clientID: UUID, data: Data) {
        guard let connection = state.read({ $0.qualityByClientID[clientID] }) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func hasVideoConnection(streamID: StreamID) -> Bool {
        state.read { $0.videoByStream[streamID] != nil }
    }

    func hasAudioConnection(clientID: UUID) -> Bool {
        state.read { $0.audioByClientID[clientID] != nil }
    }
}
#endif
