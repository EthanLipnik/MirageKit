//
//  MirageClientService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Loom stream audio transport and playback handling.
//

import CoreMedia
import Foundation
import Loom
import MirageKit

@MainActor
extension MirageClientService {
    private static let maxAudioVideoSyncSnapshotAgeSeconds: CFAbsoluteTime = 0.250
    private static let maxAudioVideoHoldSeconds: Double = 0.080
    private static let liveAudioMaxBehindNs: UInt64 = 500_000_000

    func stopAudioConnection() {
        _ = advanceAudioStreamConfigurationGeneration()
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
            _ = advanceAudioStreamConfigurationGeneration()
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
            let configurationGeneration = advanceAudioStreamConfigurationGeneration()

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
                    guard self.isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    await self.audioPacketIngressQueue.reset()
                    guard self.isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    await audioPlaybackController.reset()
                    guard self.isAudioStreamConfigurationCurrent(configurationGeneration) else { return }
                    self.publishAudioStreamStarted(
                        started,
                        preferredChannels: preferredChannels,
                        audioPlaybackController: audioPlaybackController,
                        generation: configurationGeneration
                    )
                }
            } else {
                publishAudioStreamStarted(
                    started,
                    preferredChannels: preferredChannels,
                    audioPlaybackController: audioPlaybackController,
                    generation: configurationGeneration
                )
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStarted: ")
        }
    }

    private func publishAudioStreamStarted(
        _ started: AudioStreamStartedMessage,
        preferredChannels: Int,
        audioPlaybackController: AudioPlaybackController,
        generation: UInt64
    ) {
        guard isAudioStreamConfigurationCurrent(generation) else { return }
        activeAudioStreamMessage = started
        setActiveAudioStreamIDForFiltering(started.streamID)
        setAudioDecodeTargetChannelCountForPipeline(preferredChannels)

        Task { @MainActor [weak self, audioPlaybackController] in
            guard let self else { return }
            guard self.isAudioStreamConfigurationCurrent(generation) else { return }
            _ = await audioPlaybackController.prepareForIncomingFormat(
                sampleRate: started.sampleRate,
                channelCount: preferredChannels
            )
            guard self.isAudioStreamConfigurationCurrent(generation) else { return }
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

            _ = advanceAudioStreamConfigurationGeneration()
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
        let liveFrames = liveAudioFramesToEnqueue(decodedFrames, for: streamID)
        guard !liveFrames.isEmpty else { return }
        updateAudioSyncDelay(for: streamID, nextFrame: liveFrames.first)
        flushPendingDecodedAudioFrames(for: streamID, into: audioPlaybackController)
        for decodedFrame in liveFrames {
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
        let liveFrames = liveAudioFramesToEnqueue(frames, for: streamID)
        updateAudioSyncDelay(for: streamID, nextFrame: liveFrames.first)
        for frame in liveFrames {
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

    private func liveAudioFramesToEnqueue(
        _ frames: [DecodedPCMFrame],
        for streamID: StreamID
    ) -> [DecodedPCMFrame] {
        guard !frames.isEmpty else { return [] }
        guard let videoTimestampNs = freshVideoTimestampNs(for: streamID) else {
            return frames
        }

        let filtered = Self.filterLiveAudioFramesForLiveSync(
            frames,
            videoTimestampNs: videoTimestampNs,
            maxBehindNs: Self.liveAudioMaxBehindNs
        )
        let liveFrames = filtered.frames
        let droppedCount = filtered.droppedCount
        if droppedCount > 0 {
            audioSyncDropCount &+= UInt64(droppedCount)
            logAudioSyncDropsIfNeeded(streamID: streamID)
        }
        return liveFrames
    }

    private func updateAudioSyncDelay(for streamID: StreamID, nextFrame: DecodedPCMFrame?) {
        guard let audioPlaybackController = audioPlaybackControllerIfInitialized else { return }
        guard let nextFrame else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            return
        }

        guard let videoTimestampNs = freshVideoTimestampNs(for: streamID) else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            return
        }

        if nextFrame.timestampNs > videoTimestampNs {
            let aheadSeconds = Double(nextFrame.timestampNs - videoTimestampNs) / 1_000_000_000
            let delay = min(max(0, aheadSeconds), Self.maxAudioVideoHoldSeconds)
            audioPlaybackController.setRuntimeExtraDelay(seconds: delay)
            logAudioAheadIfNeeded(streamID: streamID, aheadSeconds: aheadSeconds, delay: delay)
        } else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
        }
    }

    private func freshVideoTimestampNs(for streamID: StreamID) -> UInt64? {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        guard snapshot.sequence > 0 else { return nil }
        let ageSeconds = CFAbsoluteTimeGetCurrent() - snapshot.submittedTime
        guard ageSeconds >= 0,
              ageSeconds <= Self.maxAudioVideoSyncSnapshotAgeSeconds else {
            return nil
        }
        return Self.nanoseconds(from: snapshot.remotePresentationTime)
    }

    private func logAudioSyncDropsIfNeeded(streamID: StreamID) {
        guard MirageSteadyStateDiagnostics.isEnabled else {
            audioSyncDropCount = 0
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAudioSyncDropLogTime == 0 || now - lastAudioSyncDropLogTime > 2.0 else { return }
        MirageLogger.client(
            "Audio sync drop: stream=\(streamID), dropped=\(audioSyncDropCount) stale decoded frame(s)"
        )
        audioSyncDropCount = 0
        lastAudioSyncDropLogTime = now
    }

    private func logAudioAheadIfNeeded(streamID: StreamID, aheadSeconds: Double, delay: Double) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard delay > 0.001, lastAudioSyncAheadLogTime == 0 || now - lastAudioSyncAheadLogTime > 2.0 else {
            return
        }
        MirageLogger.client(
            "Audio sync hold: stream=\(streamID), aheadMs=\(Int((aheadSeconds * 1000).rounded())), delayMs=\(Int((delay * 1000).rounded()))"
        )
        lastAudioSyncAheadLogTime = now
    }

    private nonisolated static func nanoseconds(from time: CMTime) -> UInt64? {
        guard time.isValid else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }

    nonisolated static func filterLiveAudioFramesForLiveSync(
        _ frames: [DecodedPCMFrame],
        videoTimestampNs: UInt64?,
        maxBehindNs: UInt64 = 500_000_000
    ) -> (frames: [DecodedPCMFrame], droppedCount: Int) {
        guard let videoTimestampNs else {
            return (frames, 0)
        }
        let liveFrames = frames.filter { frame in
            let durationNs = UInt64(max(0, frame.durationSeconds) * 1_000_000_000)
            return frame.timestampNs + durationNs + maxBehindNs >= videoTimestampNs
        }
        return (liveFrames, frames.count - liveFrames.count)
    }

    private func advanceAudioStreamConfigurationGeneration() -> UInt64 {
        audioStreamConfigurationGeneration &+= 1
        return audioStreamConfigurationGeneration
    }

    private func isAudioStreamConfigurationCurrent(_ generation: UInt64) -> Bool {
        audioStreamConfigurationGeneration == generation
    }
}
