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
    private nonisolated static let maxAudioVideoSyncSnapshotAgeSeconds: CFAbsoluteTime = 0.250
    private nonisolated static let hardAudioVideoSyncSnapshotAgeSeconds: CFAbsoluteTime = 0.500
    private nonisolated static let staleVideoConfirmedDecisionCount = 2
    private nonisolated static let maxAudioVideoHoldSeconds: Double = 0.080
    private nonisolated static let liveAudioMaxBehindNs: UInt64 = 500_000_000

    private struct LiveAudioVideoSyncState {
        let videoState: LiveAudioSyncPolicy.VideoState
        let staleSnapshotAgeSeconds: CFAbsoluteTime?
    }

    func stopAudioConnection() {
        _ = advanceAudioStreamConfigurationGeneration()
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        audioRegisteredStreamID = nil
        activeAudioStreamMessage = nil
        resetPendingDecodedAudioFrames()
        setActiveAudioStreamIDForFiltering(nil)
        audioVideoGateActiveStreamIDs.removeAll()
        resetAudioStaleVideoGateState()
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
            audioVideoGateActiveStreamIDs.remove(streamID)
            resetAudioStaleVideoGateState(for: streamID)
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
            audioVideoGateActiveStreamIDs.remove(stopped.streamID)
            resetAudioStaleVideoGateState(for: stopped.streamID)
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
        let decision = liveAudioDecision(for: decodedFrames, streamID: streamID)
        applyAudioLiveSyncDiagnostics(decision, streamID: streamID)

        if decision.shouldGatePlayback {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            bufferPendingDecodedAudioTail(decision.frames, for: streamID)
            guard audioVideoGateActiveStreamIDs.insert(streamID).inserted else { return }
            audioPlaybackController.discardBufferedAudio()
            MirageLogger.client(
                "Audio sync gate active: stream=\(streamID), reason=\(decision.reason ?? "unknown")"
            )
            return
        }

        if audioVideoGateActiveStreamIDs.remove(streamID) != nil {
            MirageLogger.client("Audio sync gate resumed: stream=\(streamID)")
        }

        guard !decision.frames.isEmpty else { return }
        audioPlaybackController.setRuntimeExtraDelay(seconds: decision.runtimeExtraDelaySeconds)
        logAudioAheadIfNeeded(
            streamID: streamID,
            nextFrame: decision.frames.first,
            delay: decision.runtimeExtraDelaySeconds
        )
        if decision.reason != "stale-video-presentation-soft" {
            flushPendingDecodedAudioFrames(for: streamID, into: audioPlaybackController)
        }
        for decodedFrame in decision.frames {
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

    private func bufferPendingDecodedAudioTail(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard !decodedFrames.isEmpty else { return }
        let existingFrames = pendingDecodedAudioFramesByStreamID[streamID] ?? []
        let tail = LiveAudioSyncPolicy.decide(
            frames: existingFrames + decodedFrames,
            videoState: .waitingForFirstFrame,
            liveTailDurationSeconds: LiveAudioSyncPolicy.defaultLiveTailDurationSeconds
        ).frames
        pendingDecodedAudioFramesByStreamID[streamID] = tail
        pendingDecodedAudioDurationByStreamID[streamID] = tail.reduce(0) { $0 + $1.durationSeconds }
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
        let decision = liveAudioDecision(for: frames, streamID: streamID)
        applyAudioLiveSyncDiagnostics(decision, streamID: streamID)
        guard !decision.shouldGatePlayback else {
            bufferPendingDecodedAudioTail(decision.frames, for: streamID)
            return
        }
        audioPlaybackController.setRuntimeExtraDelay(seconds: decision.runtimeExtraDelaySeconds)
        logAudioAheadIfNeeded(
            streamID: streamID,
            nextFrame: decision.frames.first,
            delay: decision.runtimeExtraDelaySeconds
        )
        for frame in decision.frames {
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

    private func liveAudioDecision(
        for frames: [DecodedPCMFrame],
        streamID: StreamID
    ) -> LiveAudioSyncPolicy.Decision {
        let syncState = liveAudioVideoSyncState(for: streamID)
        let decision = LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: syncState.videoState,
            maxBehindNs: Self.liveAudioMaxBehindNs,
            liveTailDurationSeconds: LiveAudioSyncPolicy.defaultLiveTailDurationSeconds,
            maxHoldSeconds: Self.maxAudioVideoHoldSeconds
        )
        return decisionAfterStaleVideoGateHysteresis(
            decision,
            syncState: syncState,
            streamID: streamID
        )
    }

    private func liveAudioVideoSyncState(for streamID: StreamID) -> LiveAudioVideoSyncState {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        if snapshot.hasSubmission {
            let ageSeconds = CFAbsoluteTimeGetCurrent() - snapshot.submittedTime
            if ageSeconds >= 0,
               ageSeconds <= Self.maxAudioVideoSyncSnapshotAgeSeconds,
               let timestampNs = Self.nanoseconds(from: snapshot.remotePresentationTime) {
                return LiveAudioVideoSyncState(
                    videoState: .fresh(timestampNs: timestampNs),
                    staleSnapshotAgeSeconds: nil
                )
            }
            if streamHasPresentedVideoFrame(streamID) {
                return LiveAudioVideoSyncState(
                    videoState: .staleAfterPresentation,
                    staleSnapshotAgeSeconds: max(0, ageSeconds)
                )
            }
        }

        if streamHasPresentedVideoFrame(streamID) {
            return LiveAudioVideoSyncState(
                videoState: .staleAfterPresentation,
                staleSnapshotAgeSeconds: nil
            )
        }

        if activeMediaStreams["video/\(streamID)"] != nil ||
            sessionStore.sessionByStreamID(streamID) != nil ||
            sessionStore.sessionByMediaStreamID(streamID) != nil {
            return LiveAudioVideoSyncState(
                videoState: .waitingForFirstFrame,
                staleSnapshotAgeSeconds: nil
            )
        }

        return LiveAudioVideoSyncState(videoState: .unavailable, staleSnapshotAgeSeconds: nil)
    }

    private func freshVideoTimestampNs(for streamID: StreamID) -> UInt64? {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        guard snapshot.hasSubmission else { return nil }
        let ageSeconds = CFAbsoluteTimeGetCurrent() - snapshot.submittedTime
        guard ageSeconds >= 0,
              ageSeconds <= Self.maxAudioVideoSyncSnapshotAgeSeconds else {
            return nil
        }
        return Self.nanoseconds(from: snapshot.remotePresentationTime)
    }

    private func streamHasPresentedVideoFrame(_ streamID: StreamID) -> Bool {
        if sessionStore.sessionByStreamID(streamID)?.hasPresentedFrame == true {
            return true
        }
        if sessionStore.sessionByMediaStreamID(streamID)?.hasPresentedFrame == true {
            return true
        }
        return MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).hasSubmission
    }

    private func decisionAfterStaleVideoGateHysteresis(
        _ decision: LiveAudioSyncPolicy.Decision,
        syncState: LiveAudioVideoSyncState,
        streamID: StreamID
    ) -> LiveAudioSyncPolicy.Decision {
        guard decision.shouldGatePlayback,
              decision.reason == "stale-video-presentation" else {
            audioStaleVideoGateStateByStreamID.removeValue(forKey: streamID)
            return decision
        }

        var gateState = audioStaleVideoGateStateByStreamID[streamID] ?? AudioStaleVideoGateState(
            consecutiveDecisionCount: 0,
            maxSnapshotAgeSeconds: 0
        )
        gateState.consecutiveDecisionCount += 1
        if let staleSnapshotAgeSeconds = syncState.staleSnapshotAgeSeconds {
            gateState.maxSnapshotAgeSeconds = max(
                gateState.maxSnapshotAgeSeconds,
                staleSnapshotAgeSeconds
            )
        }
        audioStaleVideoGateStateByStreamID[streamID] = gateState

        var diagnostics = audioStaleVideoDiagnosticsByStreamID[streamID] ?? AudioStaleVideoDiagnostics()
        diagnostics.maxSnapshotAgeSeconds = max(
            diagnostics.maxSnapshotAgeSeconds,
            gateState.maxSnapshotAgeSeconds
        )
        let shouldConfirmGate = Self.shouldConfirmStaleVideoGate(
            consecutiveDecisionCount: gateState.consecutiveDecisionCount,
            staleSnapshotAgeSeconds: syncState.staleSnapshotAgeSeconds
        )
        if shouldConfirmGate {
            diagnostics.gateCount &+= 1
            diagnostics.confirmedGateCount &+= 1
            audioStaleVideoDiagnosticsByStreamID[streamID] = diagnostics
            updateAudioStaleVideoDiagnosticsSnapshot(for: streamID, diagnostics: diagnostics)
            return decision
        }

        diagnostics.softHoldCount &+= 1
        audioStaleVideoDiagnosticsByStreamID[streamID] = diagnostics
        updateAudioStaleVideoDiagnosticsSnapshot(for: streamID, diagnostics: diagnostics)
        return Self.audioDecisionAfterStaleVideoHysteresis(
            decision,
            confirmGate: false
        )
    }

    nonisolated static func shouldConfirmStaleVideoGate(
        consecutiveDecisionCount: Int,
        staleSnapshotAgeSeconds: CFAbsoluteTime?
    ) -> Bool {
        if let staleSnapshotAgeSeconds,
           staleSnapshotAgeSeconds >= hardAudioVideoSyncSnapshotAgeSeconds {
            return true
        }
        return consecutiveDecisionCount >= staleVideoConfirmedDecisionCount
    }

    nonisolated static func audioDecisionAfterStaleVideoHysteresis(
        _ decision: LiveAudioSyncPolicy.Decision,
        confirmGate: Bool
    ) -> LiveAudioSyncPolicy.Decision {
        guard decision.shouldGatePlayback,
              decision.reason == "stale-video-presentation",
              !confirmGate else {
            return decision
        }
        return LiveAudioSyncPolicy.Decision(
            frames: decision.frames,
            droppedCount: decision.droppedCount,
            shouldGatePlayback: false,
            runtimeExtraDelaySeconds: 0,
            reason: "stale-video-presentation-soft"
        )
    }

    private func resetAudioStaleVideoGateState(for streamID: StreamID? = nil) {
        if let streamID {
            audioStaleVideoGateStateByStreamID.removeValue(forKey: streamID)
            audioStaleVideoDiagnosticsByStreamID.removeValue(forKey: streamID)
            updateAudioStaleVideoDiagnosticsSnapshot(for: streamID, diagnostics: AudioStaleVideoDiagnostics())
        } else {
            let streamIDs = Set(audioStaleVideoDiagnosticsByStreamID.keys)
                .union(audioStaleVideoGateStateByStreamID.keys)
            audioStaleVideoGateStateByStreamID.removeAll()
            audioStaleVideoDiagnosticsByStreamID.removeAll()
            for streamID in streamIDs {
                updateAudioStaleVideoDiagnosticsSnapshot(for: streamID, diagnostics: AudioStaleVideoDiagnostics())
            }
        }
    }

    private func updateAudioStaleVideoDiagnosticsSnapshot(
        for streamID: StreamID,
        diagnostics: AudioStaleVideoDiagnostics
    ) {
        metricsStore.updateClientAudioSyncDiagnostics(
            streamID: streamID,
            staleVideoGateCount: diagnostics.gateCount,
            staleVideoSoftHoldCount: diagnostics.softHoldCount,
            staleVideoConfirmedGateCount: diagnostics.confirmedGateCount,
            staleVideoMaxSnapshotAgeMs: diagnostics.maxSnapshotAgeSeconds * 1000
        )
    }

    private func applyAudioLiveSyncDiagnostics(
        _ decision: LiveAudioSyncPolicy.Decision,
        streamID: StreamID
    ) {
        guard decision.droppedCount > 0 else { return }
        audioSyncDropCount &+= UInt64(decision.droppedCount)
        logAudioSyncDropsIfNeeded(streamID: streamID, reason: decision.reason)
    }

    private func logAudioSyncDropsIfNeeded(streamID: StreamID) {
        logAudioSyncDropsIfNeeded(streamID: streamID, reason: nil)
    }

    private func logAudioSyncDropsIfNeeded(streamID: StreamID, reason: String?) {
        guard MirageSteadyStateDiagnostics.isEnabled else {
            audioSyncDropCount = 0
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAudioSyncDropLogTime == 0 || now - lastAudioSyncDropLogTime > 2.0 else { return }
        let reasonText = reason.map { ", reason=\($0)" } ?? ""
        MirageLogger.client(
            "Audio sync drop: stream=\(streamID), dropped=\(audioSyncDropCount) stale decoded frame(s)\(reasonText)"
        )
        audioSyncDropCount = 0
        lastAudioSyncDropLogTime = now
    }

    private func logAudioAheadIfNeeded(streamID: StreamID, nextFrame: DecodedPCMFrame?, delay: Double) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        guard let videoTimestampNs = freshVideoTimestampNs(for: streamID),
              let nextFrame,
              nextFrame.timestampNs > videoTimestampNs else {
            return
        }
        let aheadSeconds = Double(nextFrame.timestampNs - videoTimestampNs) / 1_000_000_000
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
        return LiveAudioSyncPolicy.filterFramesBehindVideo(
            frames,
            videoTimestampNs: videoTimestampNs,
            maxBehindNs: maxBehindNs
        )
    }

    private func advanceAudioStreamConfigurationGeneration() -> UInt64 {
        audioStreamConfigurationGeneration &+= 1
        return audioStreamConfigurationGeneration
    }

    private func isAudioStreamConfigurationCurrent(_ generation: UInt64) -> Bool {
        audioStreamConfigurationGeneration == generation
    }
}
