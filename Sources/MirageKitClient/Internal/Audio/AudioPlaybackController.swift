//
//  AudioPlaybackController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Buffered audio playback for stream packets.
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

/// Buffers and plays decoded host audio frames for the client.
@MainActor
public final class AudioPlaybackController {
    /// Upper bound for extra runtime delay used to keep live audio synchronized with video.
    private static let maxRuntimeExtraDelaySeconds: Double = 0.080

    private struct PlaybackConfigurationKey: Equatable {
        let sampleRate: Int
        let channelCount: Int

        init(sampleRate: Int, channelCount: Int) {
            self.sampleRate = max(1, sampleRate)
            self.channelCount = max(1, channelCount)
        }

        init(frame: DecodedPCMFrame) {
            self.init(sampleRate: frame.sampleRate, channelCount: frame.channelCount)
        }
    }

    struct PendingPlaybackFrame {
        let frame: DecodedPCMFrame
        let generation: UInt64
    }

    final class PlaybackGraph {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        init() {
            engine.attach(playerNode)
        }
    }

    let startupBufferSeconds: Double
    let maxQueuedSeconds: Double

    var playbackGraph: PlaybackGraph?

    var configuredSampleRate: Int = 0
    var configuredChannelCount: Int = 0
    #if os(iOS) || os(visionOS)
    var configuredOutputChannelCount: Int = 0
    #endif
    var pendingFrames: [PendingPlaybackFrame] = []
    var pendingDurationSeconds: Double = 0
    var scheduledDurationSeconds: Double = 0
    var hasStartedPlayback = false
    var runtimeExtraDelaySeconds: Double = 0
    var isDelayHoldActive = false
    var isConfigured = false
    var playbackGeneration: UInt64 = 0
    private var hasPlaybackSessionLease = false
    private var configurationTask: Task<Bool, Never>?
    private var configurationTaskKey: PlaybackConfigurationKey?
    private var configurationTaskGeneration: UInt64?
    var lastQueueDepthLogTime: CFAbsoluteTime = 0

    init(startupBufferSeconds: Double = 0, maxQueuedSeconds: Double = 0.350) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
        self.maxQueuedSeconds = max(0.2, maxQueuedSeconds)
        #if os(iOS) || os(visionOS)
        installAudioSessionRecoveryObservers()
        #endif
    }

    nonisolated deinit {
        #if os(iOS) || os(visionOS)
        removeAudioSessionRecoveryObservers()
        #endif
    }

    private func tearDownPlaybackGraph() {
        if let playbackGraph {
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
        }
        playbackGraph = nil
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false
        isConfigured = false
        configuredSampleRate = 0
        configuredChannelCount = 0
        #if os(iOS) || os(visionOS)
        configuredOutputChannelCount = 0
        #endif
    }

    private func resolvePlaybackGraph() -> PlaybackGraph {
        if let playbackGraph {
            return playbackGraph
        }
        let playbackGraph = PlaybackGraph()
        self.playbackGraph = playbackGraph
        return playbackGraph
    }

    func reset() async {
        playbackGeneration &+= 1
        configurationTask?.cancel()
        configurationTask = nil
        configurationTaskKey = nil
        configurationTaskGeneration = nil
        tearDownPlaybackGraph()
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        runtimeExtraDelaySeconds = 0
        await releasePlaybackSessionIfNeeded()
    }

    func preferredChannelCount(for incomingChannelCount: Int) -> Int {
        let incoming = max(1, incomingChannelCount)
        let outputChannels = resolvedOutputChannelCount(fallback: incoming)
        if incoming >= 6, outputChannels < 6 { return 2 }
        return incoming
    }

    func resolvedOutputChannelCount(fallback: Int) -> Int {
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
        let clamped = min(max(0, seconds), Self.maxRuntimeExtraDelaySeconds)
        guard abs(clamped - runtimeExtraDelaySeconds) > 0.001 else { return }

        let previousDelay = runtimeExtraDelaySeconds
        runtimeExtraDelaySeconds = clamped
        let requiredBuffered = requiredBufferedSeconds

        if clamped > previousDelay,
           hasStartedPlayback,
           totalBufferedSeconds < requiredBuffered {
            if let playerNode = playbackGraph?.playerNode, playerNode.isPlaying {
                playerNode.pause()
            }
            isDelayHoldActive = true
        } else if clamped < previousDelay,
                  isDelayHoldActive,
                  totalBufferedSeconds >= requiredBuffered {
            isDelayHoldActive = false
        }

        drainPendingFramesIfNeeded()
    }

    func discardBufferedAudio() {
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false

        guard let playerNode = playbackGraph?.playerNode else { return }
        if playerNode.isPlaying {
            playerNode.pause()
        }
        playerNode.reset()
    }

    func enqueue(_ frame: DecodedPCMFrame) {
        let generation = startConfigurationIfNeeded(sampleRate: frame.sampleRate, channelCount: frame.channelCount)
        pendingFrames.append(PendingPlaybackFrame(frame: frame, generation: generation))
        pendingDurationSeconds += frame.durationSeconds
        trimPendingFramesIfNeeded()
        logQueueDepthIfNeeded()
        drainPendingFramesIfNeeded()
    }

    func prepareForIncomingFormat(sampleRate: Int, channelCount: Int) async {
        _ = await ensureConfigured(sampleRate: sampleRate, channelCount: channelCount)
    }

    private func ensureConfigured(sampleRate: Int, channelCount: Int) async -> Bool {
        let key = PlaybackConfigurationKey(sampleRate: sampleRate, channelCount: channelCount)
        if isConfigured,
           configuredSampleRate == key.sampleRate,
           configuredChannelCount == key.channelCount {
            return true
        }

        if let configurationTask,
           configurationTaskKey == key,
           configurationTaskGeneration == playbackGeneration {
            return await configurationTask.value
        }

        let task = startConfigurationTask(for: key)
        return await task.value
    }

    private func startConfigurationIfNeeded(sampleRate: Int, channelCount: Int) -> UInt64 {
        let key = PlaybackConfigurationKey(sampleRate: sampleRate, channelCount: channelCount)
        if isConfigured,
           configuredSampleRate == key.sampleRate,
           configuredChannelCount == key.channelCount {
            return playbackGeneration
        }

        if configurationTaskKey == key,
           configurationTaskGeneration == playbackGeneration {
            return playbackGeneration
        }

        let pendingFramesMatchKey = pendingFrames.allSatisfy { PlaybackConfigurationKey(frame: $0.frame) == key }
        if configurationTask != nil || isConfigured || !pendingFramesMatchKey {
            configurationTask?.cancel()
            configurationTask = nil
            configurationTaskKey = nil
            configurationTaskGeneration = nil
            playbackGeneration &+= 1
            resetPendingPlaybackState()
        }

        beginConfigurationTask(for: key, generation: playbackGeneration)
        return playbackGeneration
    }

    private func beginConfigurationTask(for key: PlaybackConfigurationKey, generation: UInt64? = nil) {
        let resolvedGeneration = generation ?? playbackGeneration
        let task = makeConfigurationTask(for: key, generation: resolvedGeneration)
        configurationTask = task
        configurationTaskKey = key
        configurationTaskGeneration = resolvedGeneration
    }

    private func startConfigurationTask(
        for key: PlaybackConfigurationKey,
        generation: UInt64? = nil
    ) -> Task<Bool, Never> {
        let resolvedGeneration = generation ?? playbackGeneration
        let task = makeConfigurationTask(for: key, generation: resolvedGeneration)
        configurationTask = task
        configurationTaskKey = key
        configurationTaskGeneration = resolvedGeneration
        return task
    }

    private func makeConfigurationTask(
        for key: PlaybackConfigurationKey,
        generation: UInt64
    ) -> Task<Bool, Never> {
        Task { [weak self] in
            guard let self else { return false }
            return await performConfiguration(key: key, generation: generation)
        }
    }

    private func performConfiguration(key: PlaybackConfigurationKey, generation: UInt64) async -> Bool {
        defer {
            if configurationTaskKey == key, configurationTaskGeneration == generation {
                configurationTask = nil
                configurationTaskKey = nil
                configurationTaskGeneration = nil
            }
        }

        guard isCurrentConfigurationTask(key: key, generation: generation) else {
            return false
        }

        if isConfigured,
           configuredSampleRate == key.sampleRate,
           configuredChannelCount == key.channelCount {
            return true
        }

        tearDownPlaybackGraph()
        let hadPlaybackSessionLease = hasPlaybackSessionLease

        guard await ensurePlaybackSessionConfigured(generation: generation) else {
            return false
        }

        if Task.isCancelled || !isCurrentConfigurationTask(key: key, generation: generation) {
            if !hadPlaybackSessionLease {
                await releasePlaybackSessionIfNeeded()
            }
            return false
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(key.sampleRate),
            channels: AVAudioChannelCount(key.channelCount),
            interleaved: false
        ) else {
            if !hadPlaybackSessionLease {
                await releasePlaybackSessionIfNeeded()
            }
            return false
        }

        guard isCurrentConfigurationTask(key: key, generation: generation) else {
            if !hadPlaybackSessionLease {
                await releasePlaybackSessionIfNeeded()
            }
            return false
        }

        let playbackGraph = resolvePlaybackGraph()
        playbackGraph.engine.connect(playbackGraph.playerNode, to: playbackGraph.engine.mainMixerNode, format: format)
        playbackGraph.engine.prepare()
        do {
            try playbackGraph.engine.start()
        } catch {
            MirageLogger.error(.client, error: error, message: "Audio playback engine failed to start: ")
            if !hadPlaybackSessionLease {
                await releasePlaybackSessionIfNeeded()
            }
            return false
        }

        configuredSampleRate = key.sampleRate
        configuredChannelCount = key.channelCount
        #if os(iOS) || os(visionOS)
        configuredOutputChannelCount = resolvedOutputChannelCount(fallback: key.channelCount)
        #endif
        hasStartedPlayback = false
        isDelayHoldActive = false
        isConfigured = true
        drainPendingFramesIfNeeded()
        return true
    }

    private func isCurrentConfigurationTask(key: PlaybackConfigurationKey, generation: UInt64) -> Bool {
        !Task.isCancelled &&
            playbackGeneration == generation &&
            configurationTaskKey == key &&
            configurationTaskGeneration == generation
    }

    private func ensurePlaybackSessionConfigured(generation: UInt64) async -> Bool {
        guard !hasPlaybackSessionLease else {
            return playbackGeneration == generation
        }

        guard await MirageClientAudioSessionCoordinator.shared.requestPlaybackSession() else {
            return false
        }

        guard playbackGeneration == generation else {
            await MirageClientAudioSessionCoordinator.shared.releasePlaybackSession()
            return false
        }

        hasPlaybackSessionLease = true
        return true
    }

    private func releasePlaybackSessionIfNeeded() async {
        guard hasPlaybackSessionLease else { return }
        hasPlaybackSessionLease = false
        await MirageClientAudioSessionCoordinator.shared.releasePlaybackSession()
    }

    #if os(iOS) || os(visionOS)
    nonisolated(unsafe) var audioSessionObserverTokens: [NSObjectProtocol] = []
    #endif

}
