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

private let hostAudioFirstSampleTimeout: Duration = .seconds(2)

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
        cancelAudioFirstSampleWatchdog(for: clientID)
        audioFirstSampleRetryAttemptedByClientID.remove(clientID)
        audioLastSampleTimeByClientID.removeValue(forKey: clientID)
        audioConfigurationByClientID[clientID] = configuration
        MirageLogger.host(
            "Audio activation requested for client \(clientID), stream \(sourceStreamID): " +
                "enabled=\(configuration.enabled), layout=\(configuration.channelLayout.rawValue), " +
                "quality=\(configuration.quality.rawValue)"
        )
        if let streamContext = streamsByID[sourceStreamID] {
            await streamContext.setRequestedAudioChannelCount(configuration.channelLayout.channelCount)
        }

        guard configuration.enabled else {
            await stopAudioPipeline(for: clientID, reason: .disabled)
            await closeAudioTransportIfNeeded(for: clientID)
            audioSourceStreamByClientID.removeValue(forKey: clientID)
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

        do {
            try await ensureAudioTransport(
                clientID: clientID,
                sourceStreamID: sourceStreamID,
                clientContext: clientContext
            )
        } catch {
            audioSourceStreamByClientID.removeValue(forKey: clientID)
            throw error
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
                guard await maybeSendAudioStarted(
                    clientID: clientID,
                    streamID: currentStreamID,
                    encodedFrame: encoded
                ) else {
                    return
                }
                if !packets.isEmpty {
                    recordClientMediaActivity(clientID: clientID)
                }
                for packet in packets {
                    sendAudioPacketForClient(clientID, data: packet) { [weak self] error in
                        guard let error else { return }
                        self?.dispatchControlWork(clientID: clientID) { [weak self] in
                            guard let self else { return }
                            await handleAudioSendError(
                                clientID: clientID,
                                streamID: currentStreamID,
                                error: error
                            )
                        }
                    }
                }
            }
            audioPipelinesByClientID[clientID] = pipeline
        }

        await setAudioSourceCaptureHandler(clientID: clientID, streamID: sourceStreamID)
        scheduleAudioFirstSampleWatchdog(clientID: clientID, streamID: sourceStreamID)
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
        recordCapturedAudioSample(clientID: clientID, streamID: streamID)
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
        cancelAudioFirstSampleWatchdog(for: clientID)
        audioFirstSampleRetryAttemptedByClientID.remove(clientID)
        audioLastSampleTimeByClientID.removeValue(forKey: clientID)
        if let pipeline = audioPipelinesByClientID.removeValue(forKey: clientID) {
            await pipeline.stop()
        }
        let streamID = audioSourceStreamByClientID.removeValue(forKey: clientID) ?? 0
        if streamID > 0, let context = streamsByID[streamID] {
            await context.setCapturedAudioHandler(nil)
        }
        sentAudioStartedMessageByClientID.removeValue(forKey: clientID)
        audioSendErrorReportedByClientID.remove(clientID)
        let hadStartedMessage = audioStartedMessageByClientID.removeValue(forKey: clientID) != nil
        if streamID > 0, hadStartedMessage || reason == .error {
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
        sentAudioStartedMessageByClientID.removeValue(forKey: clientID)
        audioStartedMessageByClientID.removeValue(forKey: clientID)
        audioSendErrorReportedByClientID.remove(clientID)
        transportRegistry.unregisterAudioStream(clientID: clientID)
    }

    func handleAudioSendError(clientID: UUID, streamID: StreamID, error: Error) async {
        guard audioSourceStreamByClientID[clientID] == streamID else { return }
        guard transportRegistry.hasAudioConnection(clientID: clientID) else { return }

        if audioSendErrorReportedByClientID.insert(clientID).inserted {
            MirageLogger.host(
                "Audio transport send failed for client \(clientID), stream \(streamID); reopening audio stream: \(error)"
            )
        }

        await closeAudioTransportIfNeeded(for: clientID)
        guard let configuration = audioConfigurationByClientID[clientID],
              configuration.enabled,
              let clientContext = findClientContext(clientID: clientID) else {
            return
        }

        do {
            try await ensureAudioTransport(
                clientID: clientID,
                sourceStreamID: streamID,
                clientContext: clientContext
            )
            MirageLogger.host("Reopened Loom audio stream for client \(clientID), stream \(streamID)")
        } catch {
            if isExpectedLifecycleControlSendFailure(error) ||
                isFatalConnectionError(error) ||
                LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                MirageLogger.host("Audio transport reopen stopped because the client connection closed: \(error)")
            } else {
                MirageLogger.error(.host, error: error, message: "Failed reopening audio transport: ")
            }
            if isFatalConnectionError(error) {
                await disconnectClient(clientContext.client)
            }
        }
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

    @discardableResult
    private func ensureAudioTransport(
        clientID: UUID,
        sourceStreamID: StreamID,
        clientContext: ClientContext
    ) async throws -> Bool {
        guard loomAudioStreamsByClientID[clientID] == nil else { return true }
        let audioStream = try await clientContext.controlChannel.session.openStream(
            label: "audio/\(sourceStreamID)"
        )
        loomAudioStreamsByClientID[clientID] = audioStream
        transportRegistry.registerAudioStream(audioStream, clientID: clientID)
        audioSendErrorReportedByClientID.remove(clientID)
        await sendPendingAudioStartedIfPossible(clientID: clientID)
        MirageLogger.host("Opened Loom audio stream for client \(clientID)")
        return true
    }

    private func scheduleAudioFirstSampleWatchdog(clientID: UUID, streamID: StreamID) {
        cancelAudioFirstSampleWatchdog(for: clientID)
        let activationTime = CFAbsoluteTimeGetCurrent()
        audioFirstSampleWatchdogsByClientID[clientID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: hostAudioFirstSampleTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleAudioFirstSampleWatchdogTimeout(
                clientID: clientID,
                streamID: streamID,
                activationTime: activationTime
            )
        }
    }

    private func cancelAudioFirstSampleWatchdog(for clientID: UUID) {
        audioFirstSampleWatchdogsByClientID.removeValue(forKey: clientID)?.cancel()
    }

    private func recordCapturedAudioSample(clientID: UUID, streamID: StreamID) {
        audioLastSampleTimeByClientID[clientID] = CFAbsoluteTimeGetCurrent()
        if audioFirstSampleWatchdogsByClientID[clientID] != nil {
            MirageLogger.host("First captured audio sample observed for client \(clientID), stream \(streamID)")
        }
        cancelAudioFirstSampleWatchdog(for: clientID)
        audioFirstSampleRetryAttemptedByClientID.remove(clientID)
    }

    private func handleAudioFirstSampleWatchdogTimeout(
        clientID: UUID,
        streamID: StreamID,
        activationTime: CFAbsoluteTime
    )
    async {
        audioFirstSampleWatchdogsByClientID.removeValue(forKey: clientID)
        let decision = HostAudioFirstSampleWatchdogPolicy.decision(
            audioEnabled: audioConfigurationByClientID[clientID]?.enabled == true,
            pipelineActive: audioPipelinesByClientID[clientID] != nil,
            sourceMatches: audioSourceStreamByClientID[clientID] == streamID,
            lastSampleTime: audioLastSampleTimeByClientID[clientID],
            activationTime: activationTime,
            retryAttempted: audioFirstSampleRetryAttemptedByClientID.contains(clientID)
        )

        switch decision {
        case .ignore:
            return
        case .retryCapture:
            audioFirstSampleRetryAttemptedByClientID.insert(clientID)
            MirageLogger.host(
                "Audio capture produced no first sample for client \(clientID), stream \(streamID); " +
                    "restarting capture once with audio enabled"
            )
            await streamsByID[streamID]?.restartCaptureForAudioRecovery(reason: "audio_first_sample_timeout")
            scheduleAudioFirstSampleWatchdog(clientID: clientID, streamID: streamID)
        case .fail:
            MirageLogger.host(
                "Audio capture produced no first sample after retry for client \(clientID), stream \(streamID); " +
                    "stopping audio stream"
            )
            await stopAudioPipeline(for: clientID, reason: .error)
            await closeAudioTransportIfNeeded(for: clientID)
        }
    }

    @discardableResult
    private func maybeSendAudioStarted(
        clientID: UUID,
        streamID: StreamID,
        encodedFrame: EncodedAudioFrame
    )
    async -> Bool {
        let message = AudioStreamStartedMessage(
            streamID: streamID,
            codec: encodedFrame.codec,
            sampleRate: encodedFrame.sampleRate,
            channelCount: encodedFrame.channelCount
        )
        let previousMessage = audioStartedMessageByClientID[clientID]
        audioStartedMessageByClientID[clientID] = message
        if previousMessage != message {
            sentAudioStartedMessageByClientID.removeValue(forKey: clientID)
        }
        return await sendPendingAudioStartedIfPossible(clientID: clientID)
    }

    @discardableResult
    private func sendPendingAudioStartedIfPossible(clientID: UUID) async -> Bool {
        guard let message = audioStartedMessageByClientID[clientID] else { return false }
        guard transportRegistry.hasAudioConnection(clientID: clientID) else { return false }
        guard sentAudioStartedMessageByClientID[clientID] != message else { return true }
        guard await sendAudioStreamStarted(message, toClientID: clientID) else { return false }
        sentAudioStartedMessageByClientID[clientID] = message
        return true
    }

    private func fallbackAudioSourceStreamID(for clientID: UUID, excluding streamID: StreamID) -> StreamID? {
        if let desktopStreamID,
           desktopStreamID != streamID,
           desktopStreamClientContext?.client.id == clientID {
            return desktopStreamID
        }

        return activeStreams.first(where: { $0.client.id == clientID && $0.id != streamID })?.id
    }

    private func sendAudioStreamStarted(_ message: AudioStreamStartedMessage, toClientID clientID: UUID) async -> Bool {
        guard let clientContext = findClientContext(clientID: clientID) else { return false }
        do {
            try await clientContext.send(.audioStreamStarted, content: message)
            return true
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed sending audioStreamStarted: ")
            return false
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
