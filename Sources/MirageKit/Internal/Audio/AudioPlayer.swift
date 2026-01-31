//
//  AudioPlayer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio playback with jitter buffering.
//

import Foundation
import AVFoundation

@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingDuration: TimeInterval = 0
    private var isPlaying = false
    private var lastTimestamp: UInt64 = 0
    private var isConfigured = false

    private let targetBufferDuration: TimeInterval = 0.08
    private let maxBufferDuration: TimeInterval = 0.2

    func start(format: AVAudioFormat) {
        stop()
        self.format = format
        let engineFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let mixerFormat = AVAudioFormat(
            standardFormatWithSampleRate: engineFormat.sampleRate,
            channels: engineFormat.channelCount
        ) ?? engineFormat
        outputFormat = mixerFormat
        let needsConversion = !formatsMatch(format, mixerFormat)
        if needsConversion {
            converter = AVAudioConverter(from: format, to: mixerFormat)
            if converter == nil {
                MirageLogger.error(.client, "Audio format conversion unavailable; dropping audio")
                return
            }
        } else {
            converter = nil
        }

#if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowBluetooth])
        try? session.setActive(true)
#endif

        if !isConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)
            isConfigured = true
        } else {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)
        }

        do {
            try engine.start()
        } catch {
            MirageLogger.error(.client, "Audio engine start failed: \(error)")
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, timestamp: UInt64, discontinuity: Bool) {
        if discontinuity {
            reset()
        }

        if lastTimestamp > 0, timestamp <= lastTimestamp {
            return
        }
        if lastTimestamp > 0 {
            let delta = Double(timestamp - lastTimestamp) / 1_000_000_000
            if delta > 0.5 {
                reset()
            }
        }
        lastTimestamp = timestamp

        guard let bufferToPlay = convertBufferIfNeeded(buffer) else { return }
        let duration = TimeInterval(bufferToPlay.frameLength) / bufferToPlay.format.sampleRate
        if pendingDuration > maxBufferDuration {
            return
        }

        pendingDuration += duration
        player.scheduleBuffer(bufferToPlay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingDuration = max(0, (self?.pendingDuration ?? 0) - duration)
            }
        }

        if !isPlaying, pendingDuration >= targetBufferDuration {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        pendingDuration = 0
        isPlaying = false
        lastTimestamp = 0
        outputFormat = nil
        converter = nil
    }

    private func reset() {
        stop()
        if let format {
            start(format: format)
        }
    }

    private func convertBufferIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return buffer }
        if formatsMatch(buffer.format, outputFormat) {
            return buffer
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard frameCapacity > 0 else { return nil }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            MirageLogger.error(.client, "Audio conversion failed: \(error?.localizedDescription ?? "Unknown")")
            return nil
        }

        return outputBuffer
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channelCount == rhs.channelCount &&
        lhs.commonFormat == rhs.commonFormat &&
        lhs.isInterleaved == rhs.isInterleaved
    }
}
