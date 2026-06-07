//
//  HostTransportRegistry.swift
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

/// Thread-safe registry for host media transport over Loom multiplexed streams.
final class HostTransportRegistry: @unchecked Sendable {
    /// Registered media streams keyed by the identifier that owns their lifecycle.
    private struct State {
        var videoByStream: [StreamID: any MirageQueuedUnreliableMediaStream] = [:]
        var audioByClientID: [UUID: (stream: any MirageQueuedUnreliableMediaStream, profile: MirageMedia.MirageMediaSendProfile)] = [:]
    }

    private let state = Locked(State())

    /// Registers a stream-scoped video transport.
    func registerVideoStream(_ stream: any MirageQueuedUnreliableMediaStream, streamID: StreamID) {
        state.withLock { state in
            state.videoByStream[streamID] = stream
        }
    }

    /// Removes a stream-scoped video transport.
    func unregisterVideoStream(streamID: StreamID) {
        state.withLock { state in
            state.videoByStream[streamID] = nil
        }
    }

    /// Registers a client-scoped audio transport.
    func registerAudioStream(
        _ stream: any MirageQueuedUnreliableMediaStream,
        clientID: UUID,
        profile: MirageMedia.MirageMediaSendProfile
    ) {
        state.withLock { $0.audioByClientID[clientID] = (stream, profile) }
    }

    /// Removes a client-scoped audio transport.
    func unregisterAudioStream(clientID: UUID) {
        state.withLock { $0.audioByClientID[clientID] = nil }
    }

    /// Removes client-scoped transports; stream-scoped video transports are removed by stream teardown.
    func unregisterAllStreams(clientID: UUID) {
        state.withLock { state in
            state.audioByClientID[clientID] = nil
        }
    }

    /// Sends audio if a client-scoped audio stream is registered; missing streams complete successfully.
    func sendAudio(
        clientID: UUID,
        data: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        let registration = state.read { $0.audioByClientID[clientID] }
        guard let registration else {
            onComplete(nil)
            return
        }
        registration.stream.sendUnreliableQueued(data, profile: registration.profile, onComplete: onComplete)
    }

    /// Returns whether a video transport is registered for the stream.
    func hasVideoConnection(streamID: StreamID) -> Bool {
        state.read { $0.videoByStream[streamID] != nil }
    }

    /// Returns whether an audio transport is registered for the client.
    func hasAudioConnection(clientID: UUID) -> Bool {
        state.read { $0.audioByClientID[clientID] != nil }
    }
}
#endif
