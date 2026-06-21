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
    private var activeProfile: ResolvedAudioStreamProfile?
    private var activeFallbackSettings: AudioEncodeSettings?
    private var loggedFallbackDescription: String?
    private var encodeFailureCount: UInt64 = 0
    private var lastEncodeFailureLogTime: CFAbsoluteTime = 0
    var aacConverters: [AudioConverterKey: AVAudioConverter] = [:]

    init(audioConfiguration: MirageAudioConfiguration) {
        self.audioConfiguration = audioConfiguration
        activeProfile = ResolvedAudioStreamProfile.resolve(configuration: audioConfiguration)
    }

    func updateConfiguration(_ configuration: MirageAudioConfiguration) {
        updateProfile(ResolvedAudioStreamProfile.resolve(configuration: configuration), configuration: configuration)
    }

    func updateProfile(_ profile: ResolvedAudioStreamProfile?, configuration: MirageAudioConfiguration? = nil) {
        if let configuration {
            audioConfiguration = configuration
        }
        activeProfile = profile
        activeFallbackSettings = nil
        loggedFallbackDescription = nil
        encodeFailureCount = 0
        lastEncodeFailureLogTime = 0
        aacConverters.removeAll()
    }

    func updateResolvedProfile(_ profile: ResolvedAudioStreamProfile) {
        activeProfile = profile
        audioConfiguration.compressedBitrateBps = profile.bitrateBps
        activeFallbackSettings = nil
        loggedFallbackDescription = nil
        aacConverters.removeAll()
    }

    func encode(_ captured: CapturedAudioBuffer) -> [EncodedAudioFrame] {
        guard audioConfiguration.enabled else { return [] }
        guard let inputBuffer = makeInputBuffer(captured) else {
            logEncodeFailureIfNeeded(reason: "input-buffer", captured: captured)
            return []
        }

        if let activeFallbackSettings,
           let encoded = encode(inputBuffer: inputBuffer, settings: activeFallbackSettings, timestamp: captured.presentationTime),
           !encoded.isEmpty {
            return encoded
        }

        activeFallbackSettings = nil
        guard let activeProfile else { return [] }
        let candidates = encodingCandidates(for: activeProfile)
        for (index, candidate) in candidates.enumerated() {
            guard let encoded = encode(inputBuffer: inputBuffer, settings: candidate, timestamp: captured.presentationTime),
                  !encoded.isEmpty else {
                continue
            }

            if index > 0 {
                if candidate.codec == .aacLC {
                    activeFallbackSettings = candidate
                }
                logFallbackIfNeeded(candidate)
            }
            return encoded
        }

        logEncodeFailureIfNeeded(reason: "all-candidates", captured: captured)
        return []
    }

    private func encodingCandidates(for profile: ResolvedAudioStreamProfile) -> [AudioEncodeSettings] {
        let primary = profile.encodeSettings
        var candidates = [primary]

        if primary.channelCount > AVAudioChannelCount(MirageAudioChannelLayout.stereo.channelCount),
           primary.codec == .aacLC {
            let stereoAAC = profile
                .withChannelCount(MirageAudioChannelLayout.stereo.channelCount, reason: "surround-aac-fallback")
                .encodeSettings
            if !candidates.contains(stereoAAC) {
                candidates.append(stereoAAC)
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

    private func logEncodeFailureIfNeeded(reason: String, captured: CapturedAudioBuffer) {
        encodeFailureCount &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        guard lastEncodeFailureLogTime == 0 || now - lastEncodeFailureLogTime > 2.0 else { return }
        MirageLogger.host(
            "Audio encode failed: reason=\(reason), failures=\(encodeFailureCount), " +
                "sampleRate=\(Int(captured.sampleRate.rounded())), channels=\(captured.channelCount), " +
                "frames=\(captured.frameCount), bytes=\(captured.data.count), " +
                "float=\(captured.isFloat), interleaved=\(captured.isInterleaved)"
        )
        encodeFailureCount = 0
        lastEncodeFailureLogTime = now
    }

    private func encode(
        inputBuffer: AVAudioPCMBuffer,
        settings: AudioEncodeSettings,
        timestamp: CMTime
    ) -> [EncodedAudioFrame]? {
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

            return aacFrames(
                from: compressedBuffer,
                sampleRate: Int(settings.sampleRate.rounded()),
                channelCount: Int(settings.channelCount),
                sourceFrameCount: Int(processingBuffer.frameLength),
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
            return [EncodedAudioFrame(
                data: data,
                codec: .pcm16LE,
                sampleRate: Int(settings.sampleRate.rounded()),
                channelCount: Int(settings.channelCount),
                samplesPerFrame: Int(pcm16Buffer.frameLength),
                timestampNs: timestampNs
            )]
        }
    }

    private func aacFrames(
        from compressedBuffer: AVAudioCompressedBuffer,
        sampleRate: Int,
        channelCount: Int,
        sourceFrameCount: Int,
        timestampNs: UInt64
    ) -> [EncodedAudioFrame] {
        let byteLength = Int(compressedBuffer.byteLength)
        guard byteLength > 0 else { return [] }

        let packetCount = Int(compressedBuffer.packetCount)
        guard packetCount > 1 else {
            return [
                EncodedAudioFrame(
                    data: Data(bytes: compressedBuffer.data, count: byteLength),
                    codec: .aacLC,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    samplesPerFrame: max(1, sourceFrameCount),
                    timestampNs: timestampNs
                ),
            ]
        }
        guard let packetDescriptions = compressedBuffer.packetDescriptions else { return [] }

        var frames: [EncodedAudioFrame] = []
        frames.reserveCapacity(packetCount)
        var cumulativeSamples = 0
        for packetIndex in 0 ..< packetCount {
            let description = packetDescriptions[packetIndex]
            let offset = Int(description.mStartOffset)
            let packetByteCount = Int(description.mDataByteSize)
            guard offset >= 0,
                  packetByteCount > 0,
                  offset + packetByteCount <= byteLength else {
                continue
            }

            let packetSamples = packetSampleCount(
                description,
                sourceFrameCount: sourceFrameCount,
                cumulativeSamples: cumulativeSamples
            )
            let packetTimestampNs = timestampNs + Self.nanoseconds(
                sampleOffset: cumulativeSamples,
                sampleRate: sampleRate
            )
            frames.append(
                EncodedAudioFrame(
                    data: Data(bytes: compressedBuffer.data.advanced(by: offset), count: packetByteCount),
                    codec: .aacLC,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    samplesPerFrame: packetSamples,
                    timestampNs: packetTimestampNs
                )
            )
            cumulativeSamples += packetSamples
        }
        return frames
    }

    private func packetSampleCount(
        _ description: AudioStreamPacketDescription,
        sourceFrameCount: Int,
        cumulativeSamples: Int
    ) -> Int {
        if description.mVariableFramesInPacket > 0 {
            return Int(description.mVariableFramesInPacket)
        }

        let remainingSourceSamples = sourceFrameCount - cumulativeSamples
        if remainingSourceSamples > 0 {
            return min(1_024, remainingSourceSamples)
        }
        return 1_024
    }

}

#endif
