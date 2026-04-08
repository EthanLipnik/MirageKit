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

struct HostAudioEncodingParameters: Sendable, Equatable {
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: Int
    let bitrate: Int?
}

private struct AudioEncodeSettings: Sendable {
    let codec: MirageAudioCodec
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let bitrate: Int?
}

actor AudioEncoder {
    private var audioConfiguration: MirageAudioConfiguration
    private var loggedAACFallback = false

    init(audioConfiguration: MirageAudioConfiguration) {
        self.audioConfiguration = audioConfiguration
    }

    func updateConfiguration(_ configuration: MirageAudioConfiguration) {
        audioConfiguration = configuration
        loggedAACFallback = false
    }

    func encode(_ captured: CapturedAudioBuffer) -> EncodedAudioFrame? {
        guard audioConfiguration.enabled else { return nil }
        guard let inputBuffer = makeInputBuffer(captured) else { return nil }

        let initialSettings = settings(for: audioConfiguration, fallbackChannelCount: nil)
        if let encoded = encode(inputBuffer: inputBuffer, settings: initialSettings, timestamp: captured.presentationTime) {
            return encoded
        }

        if initialSettings.codec == .aacLC,
           let pcmFallback = encode(
               inputBuffer: inputBuffer,
               settings: pcmFallbackSettings(
                   sampleRate: initialSettings.sampleRate,
                   channelCount: initialSettings.channelCount
               ),
               timestamp: captured.presentationTime
           ) {
            if !loggedAACFallback {
                loggedAACFallback = true
                MirageLogger.host("AAC audio encode failed; falling back to PCM16")
            }
            return pcmFallback
        }

        if audioConfiguration.channelLayout == .surround51 {
            let fallbackSettings = settings(
                for: audioConfiguration,
                fallbackChannelCount: AVAudioChannelCount(MirageAudioChannelLayout.stereo.channelCount)
            )
            if let encoded = encode(inputBuffer: inputBuffer, settings: fallbackSettings, timestamp: captured.presentationTime) {
                return encoded
            }
            if fallbackSettings.codec == .aacLC,
               let pcmFallback = encode(
                   inputBuffer: inputBuffer,
                   settings: pcmFallbackSettings(
                       sampleRate: fallbackSettings.sampleRate,
                       channelCount: fallbackSettings.channelCount
                   ),
                   timestamp: captured.presentationTime
               ) {
                if !loggedAACFallback {
                    loggedAACFallback = true
                    MirageLogger.host("AAC surround audio encode failed; falling back to PCM16 stereo")
                }
                return pcmFallback
            }
        }

        return nil
    }

    private func pcmFallbackSettings(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> AudioEncodeSettings {
        AudioEncodeSettings(
            codec: .pcm16LE,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitrate: nil
        )
    }

    private func settings(
        for configuration: MirageAudioConfiguration,
        fallbackChannelCount: AVAudioChannelCount?
    ) -> AudioEncodeSettings {
        let parameters = Self.encodingParameters(
            for: configuration,
            fallbackChannelCount: fallbackChannelCount.map(Int.init)
        )
        return AudioEncodeSettings(
            codec: parameters.codec,
            sampleRate: Double(parameters.sampleRate),
            channelCount: AVAudioChannelCount(parameters.channelCount),
            bitrate: parameters.bitrate
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

        let timestampNs = UInt64(CMTimeGetSeconds(timestamp) * 1_000_000_000)

        switch settings.codec {
        case .aacLC:
            guard let outputFormat = makeAACOutputFormat(
                sampleRate: settings.sampleRate,
                channels: settings.channelCount,
                bitrate: settings.bitrate
            ) else {
                return nil
            }
            guard let converter = AVAudioConverter(from: processingFormat, to: outputFormat) else { return nil }
            let packetCapacity = AVAudioPacketCount(max(1, Int(processingBuffer.frameLength)))
            let maxPacketSize = max(512, converter.maximumOutputPacketSize)
            let compressedBuffer = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: packetCapacity,
                maximumPacketSize: maxPacketSize
            )

            var providedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: compressedBuffer, error: &conversionError) { _, outStatus in
                if providedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                outStatus.pointee = .haveData
                return processingBuffer
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

    private func makeInputBuffer(_ captured: CapturedAudioBuffer) -> AVAudioPCMBuffer? {
        let commonFormat: AVAudioCommonFormat
        if captured.isFloat {
            commonFormat = .pcmFormatFloat32
        } else if captured.bitsPerChannel <= 16 {
            commonFormat = .pcmFormatInt16
        } else {
            commonFormat = .pcmFormatInt32
        }

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: captured.sampleRate,
            channels: AVAudioChannelCount(max(1, captured.channelCount)),
            interleaved: captured.isInterleaved
        ) else {
            return nil
        }

        let frameLength = AVAudioFrameCount(max(0, captured.frameCount))
        guard frameLength > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        buffer.frameLength = frameLength

        let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if captured.isInterleaved {
            guard let destination = audioBufferList.first?.mData else { return nil }
            let destinationCapacity = Int(audioBufferList.first?.mDataByteSize ?? 0)
            let byteCount = min(destinationCapacity, captured.data.count)
            captured.data.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                destination.copyMemory(from: sourceBase, byteCount: byteCount)
            }
        } else {
            var offset = 0
            for audioBuffer in audioBufferList {
                guard let destination = audioBuffer.mData else { continue }
                let destinationCapacity = Int(audioBuffer.mDataByteSize)
                guard destinationCapacity > 0 else { continue }
                let end = min(captured.data.count, offset + destinationCapacity)
                let sliceCount = max(0, end - offset)
                guard sliceCount > 0 else { continue }
                captured.data.withUnsafeBytes { source in
                    guard let sourceBase = source.baseAddress else { return }
                    destination.copyMemory(
                        from: sourceBase.advanced(by: offset),
                        byteCount: sliceCount
                    )
                }
                offset += destinationCapacity
            }
        }

        return buffer
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard inputBuffer.format == outputFormat else {
            guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else { return nil }
            let estimatedFrames = AVAudioFrameCount(
                max(
                    1,
                    Int(
                        ceil(
                            Double(inputBuffer.frameLength) * outputFormat.sampleRate /
                                max(1, inputBuffer.format.sampleRate)
                        )
                    )
                )
            )
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedFrames) else {
                return nil
            }

            var providedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if providedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            guard (status == .haveData || status == .inputRanDry), conversionError == nil else {
                return nil
            }
            return outputBuffer
        }
        return inputBuffer
    }

    private func makeAACOutputFormat(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        bitrate: Int?
    ) -> AVAudioFormat? {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
        ]
        if let bitrate {
            settings[AVEncoderBitRateKey] = bitrate
        }
        return AVAudioFormat(settings: settings)
    }

    static func encodingParameters(
        for configuration: MirageAudioConfiguration,
        fallbackChannelCount: Int? = nil
    ) -> HostAudioEncodingParameters {
        let requestedChannelCount = configuration.channelLayout.channelCount
        let channelCount = max(1, fallbackChannelCount ?? requestedChannelCount)

        switch configuration.quality {
        case .lossless:
            return HostAudioEncodingParameters(
                codec: .pcm16LE,
                sampleRate: 48_000,
                channelCount: channelCount,
                bitrate: nil
            )
        case .low:
            return HostAudioEncodingParameters(
                codec: .aacLC,
                sampleRate: 48_000,
                channelCount: channelCount,
                bitrate: aacBitrate(quality: .low, channels: channelCount)
            )
        case .high:
            return HostAudioEncodingParameters(
                codec: .aacLC,
                sampleRate: 48_000,
                channelCount: channelCount,
                bitrate: aacBitrate(quality: .high, channels: channelCount)
            )
        }
    }

    static func aacBitrate(quality: MirageAudioQuality, channels: Int) -> Int {
        switch quality {
        case .low:
            switch channels {
            case 1:
                return 64_000
            case 2:
                return 96_000
            default:
                return 256_000
            }
        case .high:
            switch channels {
            case 1:
                return 128_000
            case 2:
                return 192_000
            default:
                return 448_000
            }
        case .lossless:
            return 0
        }
    }
}

#endif
