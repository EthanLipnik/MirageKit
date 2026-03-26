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
#if os(iOS) || os(visionOS)
import UIKit
#endif

struct PlaybackAudioSessionConfiguration: Equatable {
    static let ambient = PlaybackAudioSessionConfiguration()

    private init() {}

#if os(iOS) || os(visionOS)
    var avCategory: AVAudioSession.Category {
        .ambient
    }
#endif
}

@MainActor
public final class AudioPlaybackController {
    private let startupBufferSeconds: Double
    private let maxQueuedSeconds: Double
    private let maxRuntimeExtraDelaySeconds: Double = 0.250

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var configuredSampleRate: Int = 0
    private var configuredChannelCount: Int = 0
    private var pendingFrames: [DecodedPCMFrame] = []
    private var pendingDurationSeconds: Double = 0
    private var scheduledDurationSeconds: Double = 0
    private var hasStartedPlayback = false
    private var runtimeExtraDelaySeconds: Double = 0
    private var isDelayHoldActive = false
    private var isConfigured = false
#if os(iOS) || os(visionOS)
    private var audioSessionConfigured = false
    private var hasLoggedInactiveSessionDeferral = false
    private var audioSessionActivationBackoffUntil: ContinuousClock.Instant?
    private var audioSessionActivationFailureCount: Int = 0
    private var wasApplicationInactive = false
    private static let audioSessionMaxRetries = 3
#endif

    init(startupBufferSeconds: Double = 0.150, maxQueuedSeconds: Double = 0.750) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
        self.maxQueuedSeconds = max(0.2, maxQueuedSeconds)
        engine.attach(playerNode)
    }

    private func tearDownPlaybackGraph() {
        if playerNode.isPlaying {
            playerNode.pause()
        }
        playerNode.reset()
        if engine.isRunning {
            engine.stop()
        }
        if isConfigured {
            engine.disconnectNodeOutput(playerNode)
        }
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
#if os(iOS) || os(visionOS)
        deactivateAudioSessionIfNeeded()
        hasLoggedInactiveSessionDeferral = false
#endif
    }

    func preferredChannelCount(for incomingChannelCount: Int) -> Int {
        let incoming = max(1, incomingChannelCount)
#if os(iOS) || os(visionOS)
        _ = ensureAudioSessionConfiguredForPlayback()
#endif
        let outputChannels = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
        if incoming >= 6, outputChannels < 6 { return 2 }
        return incoming
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
            if playerNode.isPlaying {
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
#if os(iOS) || os(visionOS)
        guard ensureAudioSessionConfiguredForPlayback() else { return }
#endif
        pendingFrames.append(frame)
        pendingDurationSeconds += frame.durationSeconds
        drainPendingFramesIfNeeded()
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

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(resolvedSampleRate),
            channels: AVAudioChannelCount(resolvedChannels),
            interleaved: false
        ) else {
            return false
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
#if os(iOS) || os(visionOS)
        guard ensureAudioSessionConfiguredForPlayback() else { return false }
#endif
        do {
            try engine.start()
        } catch {
            MirageLogger.error(.client, error: error, message: "Audio playback engine failed to start: ")
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
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledDurationSeconds = max(0, self.scheduledDurationSeconds - durationSeconds)
                self.drainPendingFramesIfNeeded()
            }
        }
    }

    private func startPlayerIfNeeded() {
        if !playerNode.isPlaying { playerNode.play() }
    }

#if os(iOS) || os(visionOS)
    private func ensureAudioSessionConfiguredForPlayback() -> Bool {
        guard isApplicationActive else {
            wasApplicationInactive = true
            if !hasLoggedInactiveSessionDeferral {
                MirageLogger.client("Deferring audio session activation until app becomes active")
                hasLoggedInactiveSessionDeferral = true
            }
            return false
        }
        hasLoggedInactiveSessionDeferral = false
        // Only reset backoff on inactive→active transition, not every call.
        if wasApplicationInactive {
            wasApplicationInactive = false
            audioSessionActivationFailureCount = 0
            audioSessionActivationBackoffUntil = nil
        }

        // Backoff: don't spam activation attempts after repeated failures.
        // Each failed attempt previously ran per audio packet (~60/s),
        // flooding the main thread and causing presentation stalls.
        if let backoffUntil = audioSessionActivationBackoffUntil,
           ContinuousClock.now < backoffUntil {
            return false
        }
        if audioSessionActivationFailureCount > Self.audioSessionMaxRetries {
            return false
        }

        let session = AVAudioSession.sharedInstance()
        let configuration = PlaybackAudioSessionConfiguration.ambient
        do {
            let needsReconfiguration = !audioSessionConfigured
                || session.category != configuration.avCategory
                || session.mode != .default
            if needsReconfiguration {
                try session.setCategory(configuration.avCategory, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            }
            audioSessionConfigured = true
            audioSessionActivationFailureCount = 0
            audioSessionActivationBackoffUntil = nil
            return true
        } catch {
            if shouldSuppressAudioSessionActivationError(error) {
                audioSessionActivationFailureCount += 1
                if audioSessionActivationFailureCount <= Self.audioSessionMaxRetries {
                    // Exponential backoff: 100ms, 500ms, 2s
                    let backoffs: [Duration] = [.milliseconds(100), .milliseconds(500), .seconds(2)]
                    let idx = min(audioSessionActivationFailureCount - 1, backoffs.count - 1)
                    audioSessionActivationBackoffUntil = .now + backoffs[idx]
                    MirageLogger.debug(.client,
                        "Audio session activation deferred (attempt \(audioSessionActivationFailureCount)/\(Self.audioSessionMaxRetries)): \(error)")
                } else if audioSessionActivationFailureCount == Self.audioSessionMaxRetries + 1 {
                    MirageLogger.client(
                        "Audio session activation failed after \(Self.audioSessionMaxRetries) attempts; waiting for app to become active")
                }
                return false
            }
            MirageLogger.error(.client, error: error, message: "Audio session setup failed: ")
            return false
        }
    }

    private func deactivateAudioSessionIfNeeded() {
        guard audioSessionConfigured else { return }
        audioSessionConfigured = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var isApplicationActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Attempt to upgrade the audio session to `.playback` for Picture-in-Picture.
    /// Returns `false` if another app is actively playing audio (music, podcast, etc.)
    /// or if the session cannot be activated, in which case PiP should not start.
    public func activateForPictureInPicture() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.isOtherAudioPlaying {
            MirageLogger.client("PiP audio activation skipped: other audio is playing")
            return false
        }
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioSessionConfigured = true
            MirageLogger.client("PiP audio session activated (.playback)")
            return true
        } catch {
            MirageLogger.error(.client, error: error, message: "PiP audio session activation failed: ")
            return false
        }
    }

    /// Restore the audio session to `.ambient` after Picture-in-Picture ends.
    public func deactivateForPictureInPicture() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            MirageLogger.client("PiP audio session deactivated (restored .ambient)")
        } catch {
            MirageLogger.error(.client, error: error, message: "PiP audio session restore failed: ")
        }
        audioSessionConfigured = false
    }

    private func shouldSuppressAudioSessionActivationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain
            || nsError.domain == "com.apple.coreaudio.avfaudio" else {
            return false
        }

        let deferredCodes: Set<Int> = [
            Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue),
            1836282486, // 'msrv': media services failed
            561210739, // '!ses': session unavailable while mediaserverd is recovering
            561017449, // '!ini': session not initialized
            1936290409, // 'siri': Siri/system audio session conflict (visionOS)
            -50, // kAudio_ParamError: invalid parameter (session not active)
        ]
        return deferredCodes.contains(nsError.code)
    }
#endif
}
