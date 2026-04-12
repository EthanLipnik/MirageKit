//
//  MirageHostService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Host audio stream lifecycle and packet transport.
//

import Foundation
import MirageKit
import Network

#if os(macOS)

@MainActor
extension MirageHostService {
    func updateHostAudioMuteState() {
        let shouldMuteLocalAudio = muteLocalAudioWhileStreaming && !audioPipelinesByClientID.isEmpty
        hostAudioMuteController.setMuted(shouldMuteLocalAudio)
    }

    @discardableResult
    func activateAudioForClient(
        clientID: UUID,
        expectedSessionID: UUID? = nil,
        sourceStreamID: StreamID,
        configuration: MirageAudioConfiguration
    )
    async throws -> Bool {
        let previousSourceStreamID = audioSourceStreamByClientID[clientID]
        audioConfigurationByClientID[clientID] = configuration
        if let streamContext = streamsByID[sourceStreamID] {
            await streamContext.setRequestedAudioChannelCount(configuration.channelLayout.channelCount)
        }

        guard configuration.enabled else {
            audioSourceStreamByClientID.removeValue(forKey: clientID)
            await stopAudioPipeline(for: clientID, reason: .disabled)
            await closeAudioTransportIfNeeded(for: clientID)
            return false
        }

        audioSourceStreamByClientID[clientID] = sourceStreamID
        guard !disconnectingClientIDs.contains(clientID),
              clientsByID[clientID] != nil else {
            audioSourceStreamByClientID.removeValue(forKey: clientID)
            return false
        }
        guard mediaSecurityByClientID[clientID] != nil else {
            MirageLogger.host(
                "Deferring audio pipeline activation for client \(clientID) — security context not yet available"
            )
            return false
        }

        let clientContext: ClientContext
        if let expectedSessionID {
            guard let currentClientContext = findClientContext(sessionID: expectedSessionID),
                  currentClientContext.client.id == clientID else {
                throw MirageError.protocolError("Audio transport unavailable for disconnected client \(clientID)")
            }
            clientContext = currentClientContext
        } else {
            guard let currentClientContext = findClientContext(clientID: clientID) else {
                throw MirageError.protocolError("Audio transport unavailable for disconnected client \(clientID)")
            }
            clientContext = currentClientContext
        }

        if let existingSourceStreamID = previousSourceStreamID,
           existingSourceStreamID != sourceStreamID {
            await closeAudioTransportIfNeeded(for: clientID)
        }

        // Open Loom audio stream if not already present.
        if loomAudioStreamsByClientID[clientID] == nil {
            do {
                let audioStream = try await clientContext.controlChannel.session.openStream(
                    label: "audio/\(sourceStreamID)"
                )
                loomAudioStreamsByClientID[clientID] = audioStream
                transportRegistry.registerAudioStream(audioStream, clientID: clientID)
                MirageLogger.host("Opened Loom audio stream for client \(clientID)")
            } catch {
                audioSourceStreamByClientID.removeValue(forKey: clientID)
                throw error
            }
        }

        let payloadSize = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        if let pipeline = audioPipelinesByClientID[clientID] {
            await pipeline.updateConfiguration(configuration)
            await pipeline.updateSourceStreamID(sourceStreamID)
        } else {
            let pipeline = HostAudioPipeline(
                sourceStreamID: sourceStreamID,
                audioConfiguration: configuration,
                maxPayloadSize: payloadSize,
                mediaSecurityContext: nil
            ) { [weak self] packets, encoded, currentStreamID in
                guard let self else { return }
                dispatchControlWork(clientID: clientID) { [weak self] in
                    guard let self else { return }
                    await maybeSendAudioStarted(
                        clientID: clientID,
                        streamID: currentStreamID,
                        encodedFrame: encoded
                    )
                }
                for packet in packets {
                    sendAudioPacketForClient(clientID, data: packet)
                }
            }
            audioPipelinesByClientID[clientID] = pipeline
        }

        await setAudioSourceCaptureHandler(clientID: clientID, streamID: sourceStreamID)
        updateHostAudioMuteState()
        return true
    }

    func activateDeferredAudioIfNeeded(clientID: UUID) async {
        guard let configuration = audioConfigurationByClientID[clientID],
              let sourceStreamID = audioSourceStreamByClientID[clientID],
              configuration.enabled,
              audioPipelinesByClientID[clientID] == nil else {
            return
        }
        MirageLogger.host("Retrying deferred audio activation for client \(clientID)")
        do {
            try await activateAudioForClient(
                clientID: clientID,
                sourceStreamID: sourceStreamID,
                configuration: configuration
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Deferred audio activation failed: ")
            if let clientContext = findClientContext(clientID: clientID),
               isFatalConnectionError(error) {
                await disconnectClient(clientContext.client)
            }
        }
    }

    func enqueueCapturedAudio(
        _ captured: CapturedAudioBuffer,
        from streamID: StreamID,
        clientID: UUID
    )
    async {
        guard audioSourceStreamByClientID[clientID] == streamID else { return }
        guard let pipeline = audioPipelinesByClientID[clientID] else { return }
        await pipeline.enqueue(captured)
    }

    func deactivateAudioSourceIfNeeded(streamID: StreamID) async {
        let affectedClientIDs = audioSourceStreamByClientID.compactMap { key, value in
            value == streamID ? key : nil
        }

        for clientID in affectedClientIDs {
            let fallbackStream = fallbackAudioSourceStreamID(for: clientID, excluding: streamID)
            if let fallbackStream {
                let configuration = audioConfigurationByClientID[clientID] ?? .default
                do {
                    try await activateAudioForClient(
                        clientID: clientID,
                        sourceStreamID: fallbackStream,
                        configuration: configuration
                    )
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to rebind audio source: ")
                    await stopAudioPipeline(for: clientID, reason: .sourceStopped)
                }
            } else {
                await stopAudioPipeline(for: clientID, reason: .sourceStopped)
                await closeAudioTransportIfNeeded(for: clientID)
            }
        }
    }

    func stopAudioPipeline(for clientID: UUID, reason: AudioStreamStopReason) async {
        if let pipeline = audioPipelinesByClientID.removeValue(forKey: clientID) {
            await pipeline.stop()
        }
        let streamID = audioSourceStreamByClientID.removeValue(forKey: clientID) ?? 0
        if streamID > 0, let context = streamsByID[streamID] {
            await context.setCapturedAudioHandler(nil)
        }
        if audioStartedMessageByClientID.removeValue(forKey: clientID) != nil {
            await sendAudioStreamStopped(
                AudioStreamStoppedMessage(streamID: streamID, reason: reason),
                toClientID: clientID
            )
        }

        updateHostAudioMuteState()
    }

    func stopAudioForDisconnectedClient(_ clientID: UUID) async {
        await stopAudioPipeline(for: clientID, reason: .clientRequested)
        await closeAudioTransportIfNeeded(for: clientID)
        audioConfigurationByClientID.removeValue(forKey: clientID)
        audioSourceStreamByClientID.removeValue(forKey: clientID)
    }

    func closeAudioTransportIfNeeded(for clientID: UUID) async {
        if let audioStream = loomAudioStreamsByClientID.removeValue(forKey: clientID) {
            do {
                try await audioStream.close()
            } catch {
                MirageLogger.debug(.host, "Failed to close Loom audio stream for client \(clientID): \(error)")
            }
        }
        transportRegistry.unregisterAudioStream(clientID: clientID)
    }

    private func setAudioSourceCaptureHandler(clientID: UUID, streamID: StreamID) async {
        for active in activeStreams where active.client.id == clientID {
            if active.id == streamID {
                guard let context = streamsByID[active.id] else { continue }
                await context.setCapturedAudioHandler { [weak self] captured in
                    guard let self else { return }
                    dispatchControlWork(clientID: clientID) { [weak self] in
                        guard let self else { return }
                        await enqueueCapturedAudio(captured, from: streamID, clientID: clientID)
                    }
                }
            } else if let context = streamsByID[active.id] {
                await context.setCapturedAudioHandler(nil)
            }
        }

        if let desktopStreamID, desktopStreamID == streamID, let context = streamsByID[desktopStreamID] {
            await context.setCapturedAudioHandler { [weak self] captured in
                guard let self else { return }
                dispatchControlWork(clientID: clientID) { [weak self] in
                    guard let self else { return }
                    await enqueueCapturedAudio(captured, from: streamID, clientID: clientID)
                }
            }
        }

    }

    private func maybeSendAudioStarted(
        clientID: UUID,
        streamID: StreamID,
        encodedFrame: EncodedAudioFrame
    )
    async {
        let message = AudioStreamStartedMessage(
            streamID: streamID,
            codec: encodedFrame.codec,
            sampleRate: encodedFrame.sampleRate,
            channelCount: encodedFrame.channelCount
        )
        let previousMessage = audioStartedMessageByClientID[clientID]
        audioStartedMessageByClientID[clientID] = message
        guard previousMessage != message else { return }
        guard transportRegistry.hasAudioConnection(clientID: clientID) else { return }
        await sendAudioStreamStarted(message, toClientID: clientID)
    }

    private func fallbackAudioSourceStreamID(for clientID: UUID, excluding streamID: StreamID) -> StreamID? {
        if let desktopStreamID,
           desktopStreamID != streamID,
           desktopStreamClientContext?.client.id == clientID {
            return desktopStreamID
        }

        return activeStreams.first(where: { $0.client.id == clientID && $0.id != streamID })?.id
    }

    private func sendAudioStreamStarted(_ message: AudioStreamStartedMessage, toClientID clientID: UUID) async {
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        do {
            try await clientContext.send(.audioStreamStarted, content: message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed sending audioStreamStarted: ")
        }
    }

    private func sendAudioStreamStopped(_ message: AudioStreamStoppedMessage, toClientID clientID: UUID) async {
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        do {
            try await clientContext.send(.audioStreamStopped, content: message)
        } catch {
            MirageLogger.host("Failed sending audioStreamStopped (client likely disconnected): \(error.localizedDescription)")
        }
    }
}

#endif
