//
//  HostTransportRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)

/// Thread-safe registry for host media transport over Loom multiplexed streams.
final class HostTransportRegistry: @unchecked Sendable {
    private struct State {
        var videoByStream: [StreamID: LoomMultiplexedStream] = [:]
        var audioByClientID: [UUID: LoomMultiplexedStream] = [:]
    }

    private let state = Locked(State())

    func registerVideoStream(_ stream: LoomMultiplexedStream, streamID: StreamID) {
        state.withLock { state in
            state.videoByStream[streamID] = stream
        }
    }

    @discardableResult
    func unregisterVideoStream(streamID: StreamID) -> LoomMultiplexedStream? {
        state.withLock { state in
            state.videoByStream.removeValue(forKey: streamID)
        }
    }

    func registerAudioStream(_ stream: LoomMultiplexedStream, clientID: UUID) {
        state.withLock { $0.audioByClientID[clientID] = stream }
    }

    @discardableResult
    func unregisterAudioStream(clientID: UUID) -> LoomMultiplexedStream? {
        state.withLock { $0.audioByClientID.removeValue(forKey: clientID) }
    }

    func unregisterAllStreams(clientID: UUID) {
        state.withLock { state in
            state.audioByClientID.removeValue(forKey: clientID)
        }
    }

    func sendVideo(
        streamID: StreamID,
        data: Data,
        onComplete: (@Sendable (Error?) -> Void)? = nil
    ) {
        let stream: LoomMultiplexedStream? = state.read { state in
            state.videoByStream[streamID]
        }
        guard let stream else {
            onComplete?(nil)
            return
        }

        Task {
            do {
                try await stream.sendUnreliable(data)
                onComplete?(nil)
            } catch {
                onComplete?(error)
            }
        }
    }

    func sendAudio(clientID: UUID, data: Data) {
        let stream: LoomMultiplexedStream? = state.read { $0.audioByClientID[clientID] }
        guard let stream else { return }
        Task {
            try? await stream.sendUnreliable(data)
        }
    }

    func hasVideoConnection(streamID: StreamID) -> Bool {
        state.read { $0.videoByStream[streamID] != nil }
    }

    func hasAudioConnection(clientID: UUID) -> Bool {
        state.read { $0.audioByClientID[clientID] != nil }
    }
}
#endif
