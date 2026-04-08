//
//  AudioPlaybackController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Buffered audio playback for stream packets.
//

import AVFAudio
import Foundation
import MirageKit

@MainActor
public final class AudioPlaybackController {
    private final class PlaybackGraph {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        init() {
            engine.attach(playerNode)
        }
    }

    private let startupBufferSeconds: Double
    private let maxQueuedSeconds: Double
    private let maxRuntimeExtraDelaySeconds: Double = 0.250

    private var playbackGraph: PlaybackGraph?

    private var configuredSampleRate: Int = 0
    private var configuredChannelCount: Int = 0
    private var pendingFrames: [DecodedPCMFrame] = []
    private var pendingDurationSeconds: Double = 0
    private var scheduledDurationSeconds: Double = 0
    private var hasStartedPlayback = false
    private var runtimeExtraDelaySeconds: Double = 0
    private var isDelayHoldActive = false
    private var isConfigured = false
    private var hasPlaybackSessionLease = false

    init(startupBufferSeconds: Double = 0.150, maxQueuedSeconds: Double = 0.750) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
        self.maxQueuedSeconds = max(0.2, maxQueuedSeconds)
    }

    private func tearDownPlaybackGraph() {
        guard let playbackGraph else { return }
        if playbackGraph.playerNode.isPlaying {
            playbackGraph.playerNode.pause()
        }
        playbackGraph.playerNode.reset()
        if playbackGraph.engine.isRunning {
            playbackGraph.engine.stop()
        }
        if isConfigured {
            playbackGraph.engine.disconnectNodeOutput(playbackGraph.playerNode)
        }
        self.playbackGraph = nil
    }

    private func resolvePlaybackGraph() -> PlaybackGraph {
        if let playbackGraph {
            return playbackGraph
        }
        let playbackGraph = PlaybackGraph()
        self.playbackGraph = playbackGraph
        return playbackGraph
    }

    func hasInitializedPlaybackGraphForTesting() -> Bool {
        playbackGraph != nil
    }

    func reset() {
        tearDownPlaybackGraph()
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        runtimeExtraDelaySeconds = 0
        isDelayHoldActive = false
        isConfigured = false
        configuredSampleRate = 0
        configuredChannelCount = 0
        releasePlaybackSessionIfNeeded()
    }

    func preferredChannelCount(for incomingChannelCount: Int) -> Int {
        let incoming = max(1, incomingChannelCount)
        let outputChannels = resolvedOutputChannelCount(fallback: incoming)
        if incoming >= 6, outputChannels < 6 { return 2 }
        return incoming
    }

    private func resolvedOutputChannelCount(fallback: Int) -> Int {
        if let playbackGraph {
            let channelCount = Int(playbackGraph.engine.outputNode.outputFormat(forBus: 0).channelCount)
            if channelCount > 0 {
                return channelCount
            }
        }

#if os(iOS) || os(visionOS)
        let sessionChannelCount = Int(AVAudioSession.sharedInstance().outputNumberOfChannels)
        if sessionChannelCount > 0 {
            return sessionChannelCount
        }
#endif

        return fallback
    }

    func setRuntimeExtraDelay(seconds: Double) {
        let clamped = min(max(0, seconds), maxRuntimeExtraDelaySeconds)
        guard abs(clamped - runtimeExtraDelaySeconds) > 0.001 else { return }

        let previousDelay = runtimeExtraDelaySeconds
        runtimeExtraDelaySeconds = clamped
        let requiredBuffered = requiredBufferedSeconds()

        if clamped > previousDelay,
           hasStartedPlayback,
           totalBufferedSeconds() < requiredBuffered {
            if let playerNode = playbackGraph?.playerNode, playerNode.isPlaying {
                playerNode.pause()
            }
            isDelayHoldActive = true
        } else if clamped < previousDelay,
                  isDelayHoldActive,
                  totalBufferedSeconds() >= requiredBuffered {
            isDelayHoldActive = false
        }

        drainPendingFramesIfNeeded()
    }

    func runtimeExtraDelaySecondsForTesting() -> Double {
        runtimeExtraDelaySeconds
    }

    func enqueue(_ frame: DecodedPCMFrame) {
        guard configureIfNeeded(sampleRate: frame.sampleRate, channelCount: frame.channelCount) else { return }
        pendingFrames.append(frame)
        pendingDurationSeconds += frame.durationSeconds
        drainPendingFramesIfNeeded()
    }

    @discardableResult
    func prepareForIncomingFormat(sampleRate: Int, channelCount: Int) -> Bool {
        configureIfNeeded(sampleRate: sampleRate, channelCount: channelCount)
    }

    private func configureIfNeeded(sampleRate: Int, channelCount: Int) -> Bool {
        let resolvedSampleRate = max(1, sampleRate)
        let resolvedChannels = max(1, channelCount)
        if isConfigured,
           configuredSampleRate == resolvedSampleRate,
           configuredChannelCount == resolvedChannels {
            return true
        }

        tearDownPlaybackGraph()
        let hadPlaybackSessionLease = hasPlaybackSessionLease

        guard ensurePlaybackSessionConfigured() else {
            return false
        }

        let playbackGraph = resolvePlaybackGraph()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(resolvedSampleRate),
            channels: AVAudioChannelCount(resolvedChannels),
            interleaved: false
        ) else {
            if !hadPlaybackSessionLease {
                releasePlaybackSessionIfNeeded()
            }
            return false
        }

        playbackGraph.engine.connect(playbackGraph.playerNode, to: playbackGraph.engine.mainMixerNode, format: format)
        playbackGraph.engine.prepare()
        do {
            try playbackGraph.engine.start()
        } catch {
            MirageLogger.error(.client, error: error, message: "Audio playback engine failed to start: ")
            if !hadPlaybackSessionLease {
                releasePlaybackSessionIfNeeded()
            }
            return false
        }

        configuredSampleRate = resolvedSampleRate
        configuredChannelCount = resolvedChannels
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false
        isConfigured = true
        return true
    }

    private func ensurePlaybackSessionConfigured() -> Bool {
        guard !hasPlaybackSessionLease else { return true }

        guard MirageClientAudioSessionCoordinator.shared.requestPlaybackSession() else {
            return false
        }

        hasPlaybackSessionLease = true
        return true
    }

    private func releasePlaybackSessionIfNeeded() {
        guard hasPlaybackSessionLease else { return }
        hasPlaybackSessionLease = false
        MirageClientAudioSessionCoordinator.shared.releasePlaybackSession()
    }

    private func drainPendingFramesIfNeeded() {
        let requiredBuffered = requiredBufferedSeconds()
        if !hasStartedPlayback {
            guard totalBufferedSeconds() >= requiredBuffered else { return }
            hasStartedPlayback = true
        }

        if isDelayHoldActive {
            guard totalBufferedSeconds() >= requiredBuffered else { return }
            isDelayHoldActive = false
        }

        while !pendingFrames.isEmpty, scheduledDurationSeconds <= maxQueuedSeconds {
            let frame = pendingFrames.removeFirst()
            pendingDurationSeconds = max(0, pendingDurationSeconds - frame.durationSeconds)
            schedule(frame)
        }

        if !isDelayHoldActive {
            startPlayerIfNeeded()
        }
    }

    private func requiredBufferedSeconds() -> Double {
        startupBufferSeconds + runtimeExtraDelaySeconds
    }

    private func totalBufferedSeconds() -> Double {
        pendingDurationSeconds + scheduledDurationSeconds
    }

    private func schedule(_ frame: DecodedPCMFrame) {
        let frameCount = max(0, frame.frameCount)
        guard frameCount > 0 else { return }
        let channelCount = max(1, frame.channelCount)
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

        let expectedSampleCount = frameCount * channelCount
        frame.pcmData.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            guard samples.count >= expectedSampleCount else { return }

            if channelCount == 1 {
                channelData[0].update(from: samples.baseAddress!, count: frameCount)
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
        resolvePlaybackGraph().playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledDurationSeconds = max(0, self.scheduledDurationSeconds - durationSeconds)
                self.drainPendingFramesIfNeeded()
            }
        }
    }

    private func startPlayerIfNeeded() {
        guard let playerNode = playbackGraph?.playerNode else { return }
        if !playerNode.isPlaying { playerNode.play() }
    }

}
