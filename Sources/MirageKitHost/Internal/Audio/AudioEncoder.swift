//
//  AudioEncoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Host-side audio encoding helpers.
//

import AVFAudio
import CoreMedia
import Foundation
import MirageKit

#if os(macOS)

struct EncodedAudioFrame: Sendable {
    let data: Data
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: Int
    let samplesPerFrame: Int
    let timestampNs: UInt64
}

struct AudioEncodeSettings: Sendable, Equatable {
    let codec: MirageAudioCodec
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let bitrate: Int?

    var logDescription: String {
        let bitrateText = bitrate.map { "\($0)bps" } ?? "lossless"
        return "\(codec) \(Int(sampleRate.rounded()))Hz \(channelCount)ch \(bitrateText)"
    }
}

struct AudioConverterKey: Hashable {
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: UInt32
    let bitrate: Int?
}

final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var hasProvidedInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provideInput(
        outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !hasProvidedInput else {
            outStatus.pointee = .noDataNow
            return nil
        }

        hasProvidedInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}

actor AudioEncoder {
    private var audioConfiguration: MirageAudioConfiguration
    private var activeFallbackSettings: AudioEncodeSettings?
    private var loggedFallbackDescription: String?
    var aacConverters: [AudioConverterKey: AVAudioConverter] = [:]

    init(audioConfiguration: MirageAudioConfiguration) {
        self.audioConfiguration = audioConfiguration
    }

    func updateConfiguration(_ configuration: MirageAudioConfiguration) {
        audioConfiguration = configuration
        activeFallbackSettings = nil
        loggedFallbackDescription = nil
        aacConverters.removeAll()
    }

    func encode(_ captured: CapturedAudioBuffer) -> EncodedAudioFrame? {
        guard audioConfiguration.enabled else { return nil }
        guard let inputBuffer = makeInputBuffer(captured) else { return nil }

        if let activeFallbackSettings,
           let encoded = encode(inputBuffer: inputBuffer, settings: activeFallbackSettings, timestamp: captured.presentationTime) {
            return encoded
        }

        activeFallbackSettings = nil
        let candidates = encodingCandidates(for: audioConfiguration)
        for (index, candidate) in candidates.enumerated() {
            guard let encoded = encode(inputBuffer: inputBuffer, settings: candidate, timestamp: captured.presentationTime) else {
                continue
            }

            if index > 0 {
                activeFallbackSettings = candidate
                logFallbackIfNeeded(candidate)
            }
            return encoded
        }

        return nil
    }

    private func encodingCandidates(for configuration: MirageAudioConfiguration) -> [AudioEncodeSettings] {
        let primary = settings(for: configuration, fallbackChannelCount: nil)
        var candidates = [primary]

        if configuration.channelLayout == .surround51, primary.codec == .aacLC {
            let stereoAAC = settings(
                for: configuration,
                fallbackChannelCount: AVAudioChannelCount(MirageAudioChannelLayout.stereo.channelCount)
            )
            if !candidates.contains(stereoAAC) {
                candidates.append(stereoAAC)
            }
        }

        if primary.codec == .aacLC {
            let pcmChannelCount: AVAudioChannelCount = if configuration.channelLayout == .surround51 {
                AVAudioChannelCount(MirageAudioChannelLayout.stereo.channelCount)
            } else {
                primary.channelCount
            }
            let pcm = AudioEncodeSettings(
                codec: .pcm16LE,
                sampleRate: primary.sampleRate,
                channelCount: pcmChannelCount,
                bitrate: nil
            )
            if !candidates.contains(pcm) {
                candidates.append(pcm)
            }
        }

        return candidates
    }

    private func logFallbackIfNeeded(_ settings: AudioEncodeSettings) {
        let description = settings.logDescription
        guard loggedFallbackDescription != description else { return }
        loggedFallbackDescription = description
        MirageLogger.host("Audio encode fallback active: \(description)")
    }

    private func settings(
        for configuration: MirageAudioConfiguration,
        fallbackChannelCount: AVAudioChannelCount?
    ) -> AudioEncodeSettings {
        let requestedChannelCount = configuration.channelLayout.channelCount
        let channelCount = max(1, Int(fallbackChannelCount ?? AVAudioChannelCount(requestedChannelCount)))
        let sampleRate = 48_000.0

        let codec: MirageAudioCodec
        let bitrate: Int?
        switch configuration.quality {
        case .lossless:
            codec = .pcm16LE
            bitrate = nil
        case .low:
            codec = .aacLC
            bitrate = Self.aacBitrate(quality: .low, channels: channelCount)
        case .high:
            codec = .aacLC
            bitrate = Self.aacBitrate(quality: .high, channels: channelCount)
        }

        return AudioEncodeSettings(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: AVAudioChannelCount(channelCount),
            bitrate: bitrate
        )
    }

    private func encode(
        inputBuffer: AVAudioPCMBuffer,
        settings: AudioEncodeSettings,
        timestamp: CMTime
    ) -> EncodedAudioFrame? {
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: settings.sampleRate,
            channels: settings.channelCount,
            interleaved: false
        ) else {
            return nil
        }

        guard let processingBuffer = convert(inputBuffer, to: processingFormat) else { return nil }

        let timestampNs = Self.timestampNanoseconds(from: timestamp)

        switch settings.codec {
        case .aacLC:
            guard let converter = aacConverter(from: processingFormat, settings: settings) else { return nil }
            let outputFormat = converter.outputFormat
            let packetCapacity = AVAudioPacketCount(max(1, Int(processingBuffer.frameLength)))
            let maxPacketSize = max(512, converter.maximumOutputPacketSize)
            let compressedBuffer = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: packetCapacity,
                maximumPacketSize: maxPacketSize
            )

            let inputProvider = AudioConverterInputProvider(buffer: processingBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: compressedBuffer, error: &conversionError) { _, outStatus in
                inputProvider.provideInput(outStatus: outStatus)
            }
            guard conversionError == nil else { return nil }
            guard status == .haveData || status == .inputRanDry || status == .endOfStream else { return nil }

            let byteLength = Int(compressedBuffer.byteLength)
            guard byteLength > 0 else { return nil }
            let data = Data(bytes: compressedBuffer.data, count: byteLength)
            return EncodedAudioFrame(
                data: data,
                codec: .aacLC,
                sampleRate: Int(settings.sampleRate.rounded()),
                channelCount: Int(settings.channelCount),
                samplesPerFrame: Int(processingBuffer.frameLength),
                timestampNs: timestampNs
            )

        case .pcm16LE:
            guard let pcm16Format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: settings.sampleRate,
                channels: settings.channelCount,
                interleaved: true
            ) else {
                return nil
            }
            guard let pcm16Buffer = convert(processingBuffer, to: pcm16Format) else { return nil }
            let audioBufferList = UnsafeMutableAudioBufferListPointer(pcm16Buffer.mutableAudioBufferList)
            guard let firstBuffer = audioBufferList.first,
                  let baseAddress = firstBuffer.mData else {
                return nil
            }
            let byteCount = Int(firstBuffer.mDataByteSize)
            guard byteCount > 0 else { return nil }
            let data = Data(bytes: baseAddress, count: byteCount)
            return EncodedAudioFrame(
                data: data,
                codec: .pcm16LE,
                sampleRate: Int(settings.sampleRate.rounded()),
                channelCount: Int(settings.channelCount),
                samplesPerFrame: Int(pcm16Buffer.frameLength),
                timestampNs: timestampNs
            )
        }
    }

}

#endif
