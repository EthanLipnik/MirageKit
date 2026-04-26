//
//  MirageClientService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Loom stream audio transport and playback handling.
//

import Foundation
import Loom
import MirageKit

@MainActor
extension MirageClientService {
    func stopAudioConnection() {
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        audioRegisteredStreamID = nil
        activeAudioStreamMessage = nil
        resetPendingDecodedAudioFrames()
        setActiveAudioStreamIDForFiltering(nil)
        setAudioDecodeTargetChannelCountForPipeline(2)
        if let audioPlaybackController = audioPlaybackControllerIfInitialized {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            Task { @MainActor [audioPlaybackController] in
                await audioPlaybackController.reset()
            }
        }
        Task { [audioPacketIngressQueue] in
            await audioPacketIngressQueue.reset()
        }
    }

    /// Start receiving audio packets from a Loom multiplexed stream.
    func startAudioStreamReceiveLoop(stream: LoomMultiplexedStream, streamID: StreamID) async {
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        let streamChanged = audioRegisteredStreamID != streamID
        audioRegisteredStreamID = streamID

        if streamChanged {
            if activeAudioStreamMessage?.streamID != streamID {
                activeAudioStreamMessage = nil
            }
            resetPendingDecodedAudioFrames()
            setActiveAudioStreamIDForFiltering(nil)
            setAudioDecodeTargetChannelCountForPipeline(2)
            await audioPacketIngressQueue.reset()
            if let audioPlaybackController = audioPlaybackControllerIfInitialized {
                audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
                await audioPlaybackController.reset()
            }
        }

        setActiveAudioStreamIDForFiltering(streamID)
        let serviceBox = WeakSendableBox(self)
        audioStreamReceiveTask = Task.detached(priority: .userInitiated) { [stream, streamID, serviceBox] in
            for await data in stream.incomingBytes {
                guard !Task.isCancelled else { break }
                serviceBox.value?.handleIncomingAudioData(data, expectedStreamID: streamID)
            }
            guard let service = serviceBox.value else { return }
            await service.finishAudioStreamReceiveLoop(streamID: streamID)
        }
    }

    /// Process a single audio packet received from a Loom stream.
    private nonisolated func handleIncomingAudioData(_ data: Data, expectedStreamID: StreamID) {
        guard data.count >= mirageAudioHeaderSize,
              let header = AudioPacketHeader.deserialize(from: data) else {
            return
        }

        guard header.streamID == expectedStreamID else { return }
        fastPathState.noteInboundMediaActivity()

        guard let packetContext = fastPathState.audioPacketContext(for: header.streamID) else {
            return
        }

        let generation = audioPacketIngressQueue.currentGeneration()
        let wirePayload = data.dropFirst(mirageAudioHeaderSize)
        // Loom session handles encryption, so packets arrive unencrypted.
        // Accept both encrypted and unencrypted payloads for backward compatibility.
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
        if Self.shouldValidateAudioChecksum(flags: header.flags, checksum: header.checksum) {
            guard CRC32.calculate(payloadData) == header.checksum else {
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

    nonisolated static func shouldValidateAudioChecksum(flags: AudioPacketFlags, checksum: UInt32) -> Bool {
        mirageShouldValidatePayloadChecksum(
            isEncrypted: flags.contains(.encryptedPayload),
            checksum: checksum
        )
    }

    private func finishAudioStreamReceiveLoop(streamID: StreamID) {
        if audioRegisteredStreamID == streamID {
            audioStreamReceiveTask = nil
            audioRegisteredStreamID = nil
        }
        activeMediaStreams.removeValue(forKey: "audio/\(streamID)")
        MirageLogger.client("Audio stream receive loop ended for stream \(streamID)")
    }

    func handleAudioStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AudioStreamStartedMessage.self)
            let previous = activeAudioStreamMessage
            let isReplacingActiveAudioStream = previous != nil && previous != started
            let audioPlaybackController = resolveAudioPlaybackController()
            let preferredChannels = audioPlaybackController.preferredChannelCount(for: Int(started.channelCount))

            MirageLogger
                .client(
                    "Audio stream started: stream=\(started.streamID), codec=\(started.codec), sampleRate=\(started.sampleRate), channels=\(started.channelCount)"
                )

            if isReplacingActiveAudioStream {
                activeAudioStreamMessage = nil
                setActiveAudioStreamIDForFiltering(nil)
                resetPendingDecodedAudioFrames()
                audioPacketIngressQueue.invalidatePendingPackets()
                Task { @MainActor [weak self, audioPlaybackController] in
                    guard let self else { return }
                    await self.audioPacketIngressQueue.reset()
                    await audioPlaybackController.reset()
                    self.publishAudioStreamStarted(
                        started,
                        preferredChannels: preferredChannels,
                        audioPlaybackController: audioPlaybackController
                    )
                }
            } else {
                publishAudioStreamStarted(
                    started,
                    preferredChannels: preferredChannels,
                    audioPlaybackController: audioPlaybackController
                )
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStarted: ")
        }
    }

    private func publishAudioStreamStarted(
        _ started: AudioStreamStartedMessage,
        preferredChannels: Int,
        audioPlaybackController: AudioPlaybackController
    ) {
        activeAudioStreamMessage = started
        setActiveAudioStreamIDForFiltering(started.streamID)
        setAudioDecodeTargetChannelCountForPipeline(preferredChannels)

        Task { @MainActor [weak self, audioPlaybackController] in
            guard let self else { return }
            _ = await audioPlaybackController.prepareForIncomingFormat(
                sampleRate: started.sampleRate,
                channelCount: preferredChannels
            )
            self.flushPendingDecodedAudioFrames(
                for: started.streamID,
                into: audioPlaybackController
            )
        }
    }

    func handleAudioStreamStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(AudioStreamStoppedMessage.self)
            MirageLogger.client("Audio stream stopped: stream=\(stopped.streamID), reason=\(stopped.reason)")
            let shouldReset = activeAudioStreamMessage?.streamID == stopped.streamID
            guard shouldReset else { return }

            activeAudioStreamMessage = nil
            resetPendingDecodedAudioFrames(for: stopped.streamID)
            if audioRegisteredStreamID == stopped.streamID {
                audioRegisteredStreamID = nil
            }
            setActiveAudioStreamIDForFiltering(nil)
            setAudioDecodeTargetChannelCountForPipeline(2)

            Task { [weak self] in
                guard let self else { return }
                await self.audioPacketIngressQueue.reset()
                if let audioPlaybackController = self.audioPlaybackControllerIfInitialized {
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
        let audioPlaybackController = resolveAudioPlaybackController()
        updateAudioSyncDelay(for: streamID)
        flushPendingDecodedAudioFrames(for: streamID, into: audioPlaybackController)
        for decodedFrame in decodedFrames {
            audioPlaybackController.enqueue(decodedFrame)
        }
    }

    private func bufferPendingDecodedAudioFrames(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard !decodedFrames.isEmpty else { return }
        var frames = pendingDecodedAudioFramesByStreamID[streamID] ?? []
        var duration = pendingDecodedAudioDurationByStreamID[streamID] ?? 0

        for frame in decodedFrames {
            frames.append(frame)
            duration += frame.durationSeconds
        }

        while duration > maxPendingDecodedAudioDuration, !frames.isEmpty {
            duration = max(0, duration - frames.removeFirst().durationSeconds)
        }

        pendingDecodedAudioFramesByStreamID[streamID] = frames
        pendingDecodedAudioDurationByStreamID[streamID] = duration
    }

    private func flushPendingDecodedAudioFrames(
        for streamID: StreamID,
        into audioPlaybackController: AudioPlaybackController
    ) {
        guard let frames = pendingDecodedAudioFramesByStreamID.removeValue(forKey: streamID),
              !frames.isEmpty else {
            pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
            return
        }

        pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
        updateAudioSyncDelay(for: streamID)
        for frame in frames {
            audioPlaybackController.enqueue(frame)
        }
    }

    private func resetPendingDecodedAudioFrames(for streamID: StreamID? = nil) {
        if let streamID {
            pendingDecodedAudioFramesByStreamID.removeValue(forKey: streamID)
            pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
        } else {
            pendingDecodedAudioFramesByStreamID.removeAll()
            pendingDecodedAudioDurationByStreamID.removeAll()
        }
    }

    private func updateAudioSyncDelay(for streamID: StreamID) {
        guard let audioPlaybackController = audioPlaybackControllerIfInitialized else { return }
        guard metricsStore.snapshot(for: streamID) != nil else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            return
        }

        audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
    }
}
