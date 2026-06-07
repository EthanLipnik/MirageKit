//
//  MirageClientService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Media stream audio transport and playback handling.
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

@MainActor
extension MirageClientService {
    func stopAudioConnection() {
        let stoppedStreamID = audioRegisteredStreamID
        invalidateAudioStreamConfiguration()
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        audioRegisteredStreamID = nil
        activeAudioStreamMessage = nil
        resetPendingDecodedAudioFrames()
        fastPathState.setActiveAudioStreamID(nil)
        audioVideoGateActiveStreamIDs.removeAll()
        fastPathState.setAudioDecodeTargetChannelCount(2)
        if let audioPlaybackController = audioPlaybackControllerIfInitialized {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            Task { @MainActor [audioPlaybackController] in
                await audioPlaybackController.reset()
            }
        }
        Task { [audioPacketIngressQueue] in
            await audioPacketIngressQueue.reset()
        }
        if let stoppedStreamID {
            MirageLogger.client(
                "event=stream_boundary phase=end side=client media=audio stream=\(stoppedStreamID)"
            )
        }
    }

    /// Start receiving audio packets from a multiplexed media stream.
    func startAudioStreamReceiveLoop(
        stream: any MirageIncomingMediaStream,
        streamID: StreamID
    ) async {
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        let streamChanged = audioRegisteredStreamID != streamID
        audioRegisteredStreamID = streamID

        if streamChanged {
            invalidateAudioStreamConfiguration()
            if activeAudioStreamMessage?.streamID != streamID {
                activeAudioStreamMessage = nil
            }
            resetPendingDecodedAudioFrames()
            fastPathState.setActiveAudioStreamID(nil)
            audioVideoGateActiveStreamIDs.remove(streamID)
            fastPathState.setAudioDecodeTargetChannelCount(2)
            await audioPacketIngressQueue.reset()
            if let audioPlaybackController = audioPlaybackControllerIfInitialized {
                audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
                await audioPlaybackController.reset()
            }
        }

        fastPathState.setActiveAudioStreamID(streamID)
        let serviceBox = WeakSendableBox(self)
        audioStreamReceiveTask = Task.detached(priority: .userInitiated) { [stream, streamID, serviceBox] in
            for await data in stream.incomingBytes {
                guard !Task.isCancelled else { break }
                serviceBox.value?.handleIncomingAudioData(data, expectedStreamID: streamID)
            }
            guard let service = serviceBox.value else { return }
            await MainActor.run {
                let hadActiveStream = service.audioRegisteredStreamID == streamID ||
                    service.activeMediaStreams["audio/\(streamID)"] != nil
                if service.audioRegisteredStreamID == streamID {
                    service.audioStreamReceiveTask = nil
                    service.audioRegisteredStreamID = nil
                }
                service.activeMediaStreams.removeValue(forKey: "audio/\(streamID)")
                if hadActiveStream {
                    MirageLogger.client(
                        "event=stream_boundary phase=end side=client media=audio stream=\(streamID)"
                    )
                }
                MirageLogger.client("Audio stream receive loop ended for stream \(streamID)")
            }
        }
    }

    /// Process a single audio packet received from a Loom stream.
    private nonisolated func handleIncomingAudioData(_ data: Data, expectedStreamID: StreamID) {
        guard data.count >= MirageWire.mirageAudioHeaderSize,
              let header = MirageWire.AudioPacketHeader.deserialize(from: data) else {
            return
        }

        guard header.streamID == expectedStreamID else { return }
        fastPathState.noteInboundMediaActivity()

        guard let packetContext = fastPathState.audioPacketContext(for: header.streamID) else {
            return
        }

        let generation = audioPacketIngressQueue.currentGeneration
        let wirePayload = data.dropFirst(MirageWire.mirageAudioHeaderSize)
        // Local media encryption adds packet-level auth tags on top of the Loom session.
        let expectedWireLength = header.flags.contains(.encryptedPayload)
            ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
            : Int(header.payloadLength)
        guard wirePayload.count == expectedWireLength else {
            return
        }
        let payloadData: Data
        if header.flags.contains(.encryptedPayload) {
            guard let mediaPacketKey = packetContext.mediaPacketKey else {
                return
            }
            do {
                payloadData = try MirageMediaSecurity.decryptAudioPayload(
                    wirePayload,
                    header: header,
                    key: mediaPacketKey,
                    direction: .hostToClient
                )
            } catch {
                return
            }
            guard payloadData.count == Int(header.payloadLength) else {
                return
            }
        } else {
            payloadData = Data(wirePayload)
        }
        if !header.flags.contains(.encryptedPayload) {
            guard MirageWire.CRC32.calculate(payloadData) == header.checksum else {
                return
            }
        }

        audioPacketIngressQueue.enqueue(
            header: header,
            payload: payloadData,
            targetChannelCount: packetContext.targetChannelCount,
            generation: generation
        )
    }

    func handleAudioStreamStarted(_ message: MirageWire.ControlMessage) {
        do {
            let started = try message.decode(MirageWire.AudioStreamStartedMessage.self)
            let previous = activeAudioStreamMessage
            let isReplacingActiveAudioStream = previous != nil && previous != started
            let playbackController = audioPlaybackController
            let preferredChannels = playbackController.preferredChannelCount(for: Int(started.channelCount))
            invalidateAudioStreamConfiguration()
            let configurationGeneration = audioStreamConfigurationGeneration

            MirageLogger
                .client(
                    "Audio stream started: stream=\(started.streamID), codec=\(started.codec), sampleRate=\(started.sampleRate), channels=\(started.channelCount)"
                )

            if isReplacingActiveAudioStream {
                activeAudioStreamMessage = nil
                fastPathState.setActiveAudioStreamID(nil)
                resetPendingDecodedAudioFrames()
                audioPacketIngressQueue.invalidatePendingPackets()
                Task { @MainActor [weak self, playbackController] in
                    guard let self else { return }
                    guard isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    await audioPacketIngressQueue.reset()
                    guard isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    await playbackController.reset()
                    guard isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    publishAudioStreamStarted(
                        started,
                        preferredChannels: preferredChannels,
                        audioPlaybackController: playbackController,
                        generation: configurationGeneration
                    )
                }
            } else {
                publishAudioStreamStarted(
                    started,
                    preferredChannels: preferredChannels,
                    audioPlaybackController: playbackController,
                    generation: configurationGeneration
                )
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStarted: ")
        }
    }

    private func publishAudioStreamStarted(
        _ started: MirageWire.AudioStreamStartedMessage,
        preferredChannels: Int,
        audioPlaybackController: AudioPlaybackController,
        generation: UInt64
    ) {
        guard isAudioStreamConfigurationCurrent(generation) else { return }
        activeAudioStreamMessage = started
        fastPathState.setActiveAudioStreamID(started.streamID)
        fastPathState.setAudioDecodeTargetChannelCount(preferredChannels)

        Task { @MainActor [weak self, audioPlaybackController] in
            guard let self else { return }
            guard isAudioStreamConfigurationCurrent(generation) else { return }
            await audioPlaybackController.prepareForIncomingFormat(
                sampleRate: started.sampleRate,
                channelCount: preferredChannels
            )
            guard isAudioStreamConfigurationCurrent(generation) else { return }
            flushPendingDecodedAudioFrames(
                for: started.streamID,
                into: audioPlaybackController
            )
        }
    }

    func handleAudioStreamStopped(_ message: MirageWire.ControlMessage) {
        do {
            let stopped = try message.decode(MirageWire.AudioStreamStoppedMessage.self)
            MirageLogger.client("Audio stream stopped: stream=\(stopped.streamID), reason=\(stopped.reason)")
            let shouldReset = activeAudioStreamMessage?.streamID == stopped.streamID
            guard shouldReset else { return }

            invalidateAudioStreamConfiguration()
            activeAudioStreamMessage = nil
            resetPendingDecodedAudioFrames(for: stopped.streamID)
            audioVideoGateActiveStreamIDs.remove(stopped.streamID)
            if audioRegisteredStreamID == stopped.streamID {
                audioRegisteredStreamID = nil
            }
            fastPathState.setActiveAudioStreamID(nil)
            fastPathState.setAudioDecodeTargetChannelCount(2)

            Task { [weak self] in
                guard let self else { return }
                await audioPacketIngressQueue.reset()
                if let audioPlaybackController = audioPlaybackControllerIfInitialized {
                    audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
                    await audioPlaybackController.reset()
                }
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStopped: ")
        }
    }

    func enqueueDecodedAudioFrames(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard audioConfiguration.enabled else { return }
        guard activeAudioStreamMessage?.streamID == streamID else {
            if audioRegisteredStreamID == streamID {
                bufferPendingDecodedAudioFrames(decodedFrames, for: streamID)
            }
            return
        }
        guard !decodedFrames.isEmpty else { return }
        let playbackController = audioPlaybackController
        let decision = liveAudioDecision(for: decodedFrames, streamID: streamID)
        applyAudioLiveSyncDiagnostics(decision, streamID: streamID)

        if decision.shouldGatePlayback {
            playbackController.setRuntimeExtraDelay(seconds: 0)
            bufferPendingDecodedAudioTail(decision.frames, for: streamID)
            guard audioVideoGateActiveStreamIDs.insert(streamID).inserted else { return }
            playbackController.discardBufferedAudio()
            MirageLogger.client(
                "Audio sync gate active: stream=\(streamID), reason=\(decision.reason ?? "unknown")"
            )
            return
        }

        if audioVideoGateActiveStreamIDs.remove(streamID) != nil {
            MirageLogger.client("Audio sync gate resumed: stream=\(streamID)")
        }

        guard !decision.frames.isEmpty else { return }
        playbackController.setRuntimeExtraDelay(seconds: decision.runtimeExtraDelaySeconds)
        logAudioAheadIfNeeded(
            streamID: streamID,
            nextFrame: decision.frames.first,
            delay: decision.runtimeExtraDelaySeconds
        )
        flushPendingDecodedAudioFrames(for: streamID, into: playbackController)
        for decodedFrame in decision.frames {
            playbackController.enqueue(decodedFrame)
        }
    }

    private func invalidateAudioStreamConfiguration() {
        audioStreamConfigurationGeneration &+= 1
    }

    private func isAudioStreamConfigurationCurrent(_ generation: UInt64) -> Bool {
        audioStreamConfigurationGeneration == generation
    }
}
