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

    private struct PendingPlaybackFrame {
        let frame: DecodedPCMFrame
        let generation: UInt64
    }

    private final class PlaybackGraph {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        init() {
            engine.attach(playerNode)
        }
    }

    private static var defaultAutomaticallyStartsPlayer: Bool {
        let isRunningTests = Bundle.main.bundlePath.contains(".xctest") ||
            CommandLine.arguments.contains { argument in
                argument.contains(".xctest") || argument.contains("swiftpm-testing-helper")
            }
        return !isRunningTests
    }

    private let startupBufferSeconds: Double
    private let maxQueuedSeconds: Double
    private let maxRuntimeExtraDelaySeconds: Double = 0.080
    private let automaticallyStartsPlayer: Bool

    private var playbackGraph: PlaybackGraph?

    private var configuredSampleRate: Int = 0
    private var configuredChannelCount: Int = 0
    private var configuredOutputChannelCount: Int = 0
    private var pendingFrames: [PendingPlaybackFrame] = []
    private var pendingDurationSeconds: Double = 0
    private var scheduledDurationSeconds: Double = 0
    private var hasStartedPlayback = false
    private var runtimeExtraDelaySeconds: Double = 0
    private var isDelayHoldActive = false
    private var isConfigured = false
    private var playbackGeneration: UInt64 = 0
    private var hasPlaybackSessionLease = false
    private var configurationTask: Task<Bool, Never>?
    private var configurationTaskKey: PlaybackConfigurationKey?
    private var configurationTaskGeneration: UInt64?
    nonisolated(unsafe) private var audioSessionObserverTokens: [NSObjectProtocol] = []
    private var lastQueueDepthLogTime: CFAbsoluteTime = 0

    init(
        startupBufferSeconds: Double = 0,
        maxQueuedSeconds: Double = 0.350,
        automaticallyStartsPlayer: Bool? = nil
    ) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
        self.maxQueuedSeconds = max(0.2, maxQueuedSeconds)
        self.automaticallyStartsPlayer = automaticallyStartsPlayer ?? Self.defaultAutomaticallyStartsPlayer
        installAudioSessionRecoveryObservers()
    }

    nonisolated deinit {
        removeAudioSessionRecoveryObservers()
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
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false
        isConfigured = false
        configuredSampleRate = 0
        configuredChannelCount = 0
        configuredOutputChannelCount = 0
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

    func reset() async {
        playbackGeneration &+= 1
        configurationTask?.cancel()
        configurationTask = nil
        configurationTaskKey = nil
        configurationTaskGeneration = nil
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
        configuredOutputChannelCount = 0
        await releasePlaybackSessionIfNeeded()
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

    func runtimeExtraDelaySecondsForTesting() -> Double {
        runtimeExtraDelaySeconds
    }

    func enqueue(_ frame: DecodedPCMFrame) {
        let generation = startConfigurationIfNeeded(sampleRate: frame.sampleRate, channelCount: frame.channelCount)
        pendingFrames.append(PendingPlaybackFrame(frame: frame, generation: generation))
        pendingDurationSeconds += frame.durationSeconds
        trimPendingFramesIfNeeded()
        logQueueDepthIfNeeded()
        drainPendingFramesIfNeeded()
    }

    @discardableResult
    func prepareForIncomingFormat(sampleRate: Int, channelCount: Int) async -> Bool {
        await ensureConfigured(sampleRate: sampleRate, channelCount: channelCount)
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

    @discardableResult
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

        _ = startConfigurationTask(for: key, generation: playbackGeneration)
        return playbackGeneration
    }

    @discardableResult
    private func startConfigurationTask(
        for key: PlaybackConfigurationKey,
        generation: UInt64? = nil
    ) -> Task<Bool, Never> {
        let generation = generation ?? playbackGeneration
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performConfiguration(key: key, generation: generation)
        }
        configurationTask = task
        configurationTaskKey = key
        configurationTaskGeneration = generation
        return task
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
        configuredOutputChannelCount = resolvedOutputChannelCount(fallback: key.channelCount)
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

    private func installAudioSessionRecoveryObservers() {
        #if os(iOS) || os(visionOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        audioSessionObserverTokens = names.map { name in
            center.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                let reason = notification.name.rawValue
                Task { @MainActor [weak self, reason] in
                    guard let self else { return }
                    await self.handleAudioSessionRecovery(reason: reason)
                }
            }
        }
        let routeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self, reasonValue] in
                guard let self else { return }
                await self.handleAudioRouteChange(reasonValue: reasonValue)
            }
        }
        audioSessionObserverTokens.append(routeToken)
        #endif
    }

    private nonisolated func removeAudioSessionRecoveryObservers() {
        #if os(iOS) || os(visionOS)
        let center = NotificationCenter.default
        for token in audioSessionObserverTokens {
            center.removeObserver(token)
        }
        audioSessionObserverTokens.removeAll()
        #endif
    }

    private func resetPendingPlaybackState() {
        pendingFrames.removeAll()
        pendingDurationSeconds = 0
        scheduledDurationSeconds = 0
        hasStartedPlayback = false
        isDelayHoldActive = false
    }

    private func drainPendingFramesIfNeeded() {
        guard isConfigured else { return }
        guard playbackGraph != nil else { return }

        let requiredBuffered = requiredBufferedSeconds()
        if !hasStartedPlayback {
            guard totalBufferedSeconds() >= requiredBuffered else { return }
            hasStartedPlayback = true
        }

        if isDelayHoldActive {
            guard totalBufferedSeconds() >= requiredBuffered else { return }
            isDelayHoldActive = false
        }

        while !pendingFrames.isEmpty {
            let pendingFrame = pendingFrames[0]
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

    private func requiredBufferedSeconds() -> Double {
        startupBufferSeconds + runtimeExtraDelaySeconds
    }

    private func totalBufferedSeconds() -> Double {
        pendingDurationSeconds + scheduledDurationSeconds
    }

    private func trimPendingFramesIfNeeded() {
        let pendingLimitSeconds = min(maxQueuedSeconds, max(startupBufferSeconds, 0.500))
        while pendingDurationSeconds > pendingLimitSeconds, !pendingFrames.isEmpty {
            let removed = pendingFrames.removeFirst()
            pendingDurationSeconds = max(0, pendingDurationSeconds - removed.frame.durationSeconds)
        }
    }

    private func frameMatchesConfiguredFormat(_ frame: DecodedPCMFrame) -> Bool {
        frame.sampleRate == configuredSampleRate &&
            frame.channelCount == configuredChannelCount
    }

    private func schedule(_ frame: DecodedPCMFrame, generation: UInt64) {
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
                guard self.playbackGeneration == generation else { return }
                self.scheduledDurationSeconds = max(0, self.scheduledDurationSeconds - durationSeconds)
                self.drainPendingFramesIfNeeded()
            }
        }
    }

    private func startPlayerIfNeeded() {
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
        guard automaticallyStartsPlayer else { return }
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func requestPlaybackGraphRecovery(reason: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            MirageLogger.client("Resetting audio playback graph after \(reason)")
            await self.reset()
        }
    }

    func recoverPlaybackGraphForTesting(reason: String = "test") async {
        await handleAudioSessionRecovery(reason: reason)
    }

    private func handleAudioSessionRecovery(reason: String) async {
        MirageLogger.client("Audio playback session recovery: \(reason)")
        await reset()
    }

    #if os(iOS) || os(visionOS)
    private func handleAudioRouteChange(reasonValue: UInt?) async {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              Self.shouldRecoverPlaybackForRouteChange(reason) else {
            return
        }
        guard isConfigured, configuredOutputChannelCount > 0 else { return }
        let currentOutputChannelCount = resolvedOutputChannelCount(fallback: configuredOutputChannelCount)
        guard currentOutputChannelCount > 0,
              currentOutputChannelCount != configuredOutputChannelCount else {
            return
        }

        await handleAudioSessionRecovery(reason: "route-change-\(reason.rawValue)")
    }

    nonisolated static func shouldRecoverPlaybackForRouteChange(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange:
            return true
        case .unknown, .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory:
            return false
        @unknown default:
            return false
        }
    }
    #endif

    private func logQueueDepthIfNeeded() {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastQueueDepthLogTime == 0 || now - lastQueueDepthLogTime > 2.0 else { return }
        let queuedMs = Int((totalBufferedSeconds() * 1000).rounded())
        MirageLogger.client("Audio playback queued=\(queuedMs)ms")
        lastQueueDepthLogTime = now
    }

    func pendingFrameCountForTesting() -> Int {
        pendingFrames.count
    }

    func pendingDurationSecondsForTesting() -> Double {
        pendingDurationSeconds
    }

}
