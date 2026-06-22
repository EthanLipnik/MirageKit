//
//  AudioPlaybackController+Queue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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
import AVFAudio
import Foundation

extension AudioPlaybackController {
    /// Clears queued and scheduled audio without rebuilding the playback graph.
    func resetPendingPlaybackState() {
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false
    }

    /// Schedules queued frames once startup buffering and live-sync delay requirements are met.
    func drainPendingFramesIfNeeded() {
        guard isConfigured else { return }
        guard playbackGraph != nil else { return }

        let requiredBuffered = requiredBufferedSeconds
        if !hasStartedPlayback {
            guard totalBufferedSeconds >= requiredBuffered else { return }
            hasStartedPlayback = true
        }

        if isDelayHoldActive {
            guard totalBufferedSeconds >= requiredBuffered else { return }
            isDelayHoldActive = false
        }

        while let pendingFrame = pendingFrames.first {
            let frame = pendingFrame.frame
            if scheduledDurationSeconds > 0,
               scheduledDurationSeconds + frame.durationSeconds > maxQueuedSeconds {
                break
            }
            pendingFrames.removeFirst()
            pendingDurationSeconds = max(0, pendingDurationSeconds - frame.durationSeconds)
            guard pendingFrame.generation == playbackGeneration else { continue }
            guard frameMatchesConfiguredFormat(frame) else { continue }
            schedule(frame, generation: pendingFrame.generation)
        }

        if !isDelayHoldActive {
            startPlayerIfNeeded()
        }
    }

    /// Buffered duration required before playback can start or resume.
    var requiredBufferedSeconds: Double {
        startupBufferSeconds + runtimeExtraDelaySeconds
    }

    /// Total audio duration retained by pending and already scheduled buffers.
    var totalBufferedSeconds: Double {
        pendingDurationSeconds + scheduledDurationSeconds
    }

    /// Keeps pending audio bounded before it reaches the player node.
    func trimPendingFramesIfNeeded() {
        let pendingLimitSeconds = min(maxQueuedSeconds, max(startupBufferSeconds, 0.500))
        while pendingDurationSeconds > pendingLimitSeconds, !pendingFrames.isEmpty {
            let removed = pendingFrames.removeFirst()
            pendingDurationSeconds = max(0, pendingDurationSeconds - removed.frame.durationSeconds)
        }
    }

    /// Returns whether a decoded PCM frame matches the active playback graph format.
    func frameMatchesConfiguredFormat(_ frame: DecodedPCMFrame) -> Bool {
        frame.sampleRate == configuredSampleRate &&
            frame.channelCount == configuredChannelCount
    }

    /// Converts an interleaved decoded frame into an `AVAudioPCMBuffer` and schedules it.
    func schedule(_ frame: DecodedPCMFrame, generation: UInt64) {
        guard generation == playbackGeneration else { return }
        guard isConfigured, frameMatchesConfiguredFormat(frame) else { return }
        guard let playbackGraph else { return }

        let frameCount = max(0, frame.frameCount)
        guard frameCount > 0 else { return }
        let channelCount = max(1, frame.channelCount)
        let expectedSampleCount = frameCount * channelCount
        guard frame.pcmData.count >= expectedSampleCount * MemoryLayout<Float>.size else {
            return
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            return
        }

        frame.pcmData.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            guard samples.count >= expectedSampleCount, let baseAddress = samples.baseAddress else { return }

            if channelCount == 1 {
                channelData[0].update(from: baseAddress, count: frameCount)
                return
            }

            for sampleIndex in 0 ..< frameCount {
                let sourceBase = sampleIndex * channelCount
                for channelIndex in 0 ..< channelCount {
                    channelData[channelIndex][sampleIndex] = samples[sourceBase + channelIndex]
                }
            }
        }

        scheduledDurationSeconds += frame.durationSeconds
        let durationSeconds = frame.durationSeconds
        playbackGraph.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard playbackGeneration == generation else { return }
                scheduledDurationSeconds = max(0, scheduledDurationSeconds - durationSeconds)
                drainPendingFramesIfNeeded()
            }
        }
    }

    /// Starts or restarts the player node after buffers are scheduled.
    func startPlayerIfNeeded() {
        guard isConfigured else { return }
        guard let playbackGraph else { return }
        if !playbackGraph.engine.isRunning {
            do {
                try playbackGraph.engine.start()
            } catch {
                MirageLogger.error(.client, error: error, message: "Audio playback engine restart failed: ")
                requestPlaybackGraphRecovery(reason: "engine-start-failed")
                return
            }
        }
        let playerNode = playbackGraph.playerNode
        if !playerNode.isPlaying { playerNode.play() }
        if scheduledDurationSeconds > 0, loggedPlaybackActiveGeneration != playbackGeneration {
            loggedPlaybackActiveGeneration = playbackGeneration
            MirageLogger.client("Audio playback active: \(diagnosticSummary)")
        }
    }

    /// Rebuilds the graph when the audio engine fails after configuration.
    func requestPlaybackGraphRecovery(reason: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            MirageLogger.client("Resetting audio playback graph after \(reason)")
            await reset()
        }
    }

    /// Emits occasional queue-depth diagnostics when steady-state diagnostics are enabled.
    func logQueueDepthIfNeeded() {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastQueueDepthLogTime == 0 || now - lastQueueDepthLogTime > 2.0 else { return }
        let queuedMs = Int((totalBufferedSeconds * 1000).rounded())
        MirageLogger.client("Audio playback queued=\(queuedMs)ms")
        lastQueueDepthLogTime = now
    }

}
