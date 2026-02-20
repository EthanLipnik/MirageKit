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

    func activateAudioForClient(
        clientID: UUID,
        sourceStreamID: StreamID,
        configuration: MirageAudioConfiguration
    )
    async {
        audioConfigurationByClientID[clientID] = configuration

        guard configuration.enabled else {
            audioSourceStreamByClientID.removeValue(forKey: clientID)
            await stopAudioPipeline(for: clientID, reason: .disabled)
            return
        }

        audioSourceStreamByClientID[clientID] = sourceStreamID
        let payloadSize = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        if let pipeline = audioPipelinesByClientID[clientID] {
            await pipeline.updateConfiguration(configuration)
            await pipeline.updateSourceStreamID(sourceStreamID)
        } else {
            guard let mediaSecurityContext = mediaSecurityByClientID[clientID] else {
                MirageLogger.error(.host, "Cannot activate audio pipeline without media security context for client \(clientID)")
                await stopAudioPipeline(for: clientID, reason: .disabled)
                return
            }
            let pipeline = HostAudioPipeline(
                sourceStreamID: sourceStreamID,
                audioConfiguration: configuration,
                maxPayloadSize: payloadSize,
                mediaSecurityContext: mediaSecurityContext
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
    }

    func handleAudioConnectionRegistered(clientID: UUID, streamID: StreamID) async {
        if audioSourceStreamByClientID[clientID] == nil {
            audioSourceStreamByClientID[clientID] = streamID
        }
        if let message = audioStartedMessageByClientID[clientID] {
            await sendAudioStreamStarted(message, toClientID: clientID)
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
                await activateAudioForClient(
                    clientID: clientID,
                    sourceStreamID: fallbackStream,
                    configuration: configuration
                )
            } else {
                await stopAudioPipeline(for: clientID, reason: .sourceStopped)
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
        if let connection = audioConnectionsByClientID.removeValue(forKey: clientID) { connection.cancel() }
        if let connection = transportRegistry.unregisterAudioConnection(clientID: clientID) { connection.cancel() }
        audioConfigurationByClientID.removeValue(forKey: clientID)
        audioSourceStreamByClientID.removeValue(forKey: clientID)
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

        if let loginDisplayStreamID, loginDisplayStreamID == streamID, let context = streamsByID[loginDisplayStreamID] {
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

        if let loginDisplayStreamID,
           loginDisplayStreamID != streamID,
           clientsByID[clientID] != nil {
            return loginDisplayStreamID
        }

        return activeStreams.first(where: { $0.client.id == clientID && $0.id != streamID })?.id
    }

    private func sendAudioStreamStarted(_ message: AudioStreamStartedMessage, toClientID clientID: UUID) async {
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        do {
            try await clientContext.send(.audioStreamStarted, content: message)
        } catch {
            MirageLogger.error(.host, "Failed sending audioStreamStarted: \(error)")
        }
    }

    private func sendAudioStreamStopped(_ message: AudioStreamStoppedMessage, toClientID clientID: UUID) async {
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        do {
            try await clientContext.send(.audioStreamStopped, content: message)
        } catch {
            MirageLogger.error(.host, "Failed sending audioStreamStopped: \(error)")
        }
    }
}

#endif
