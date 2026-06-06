//
//  AudioEncoder+Formats.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Audio format conversion helpers for host audio encoding.
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
import CoreMedia
import Foundation

#if os(macOS)

extension AudioEncoder {
    func makeInputBuffer(_ captured: CapturedAudioBuffer) -> AVAudioPCMBuffer? {
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

    func aacConverter(
        from inputFormat: AVAudioFormat,
        settings: AudioEncodeSettings
    ) -> AVAudioConverter? {
        let key = AudioConverterKey(
            codec: settings.codec,
            sampleRate: Int(settings.sampleRate.rounded()),
            channelCount: settings.channelCount,
            bitrate: settings.bitrate
        )
        if let converter = aacConverters[key],
           converter.inputFormat == inputFormat {
            return converter
        }

        guard let outputFormat = makeAACOutputFormat(
            sampleRate: settings.sampleRate,
            channels: settings.channelCount,
            bitrate: settings.bitrate
        ) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        aacConverters[key] = converter
        return converter
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
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

            let inputProvider = AudioConverterInputProvider(buffer: inputBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                inputProvider.provideInput(outStatus: outStatus)
            }
            guard status == .haveData || status == .inputRanDry, conversionError == nil else {
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

    nonisolated static func timestampNanoseconds(from timestamp: CMTime) -> UInt64 {
        guard timestamp.isValid else { return 0 }
        let seconds = CMTimeGetSeconds(timestamp)
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    static func aacBitrate(
        quality: MirageMedia.MirageAudioQuality,
        channels: Int,
        budgetBps: Int? = nil
    ) -> Int {
        let fallbackLayout: MirageMedia.MirageAudioChannelLayout = switch channels {
        case 1:
            .mono
        case 2:
            .stereo
        default:
            .surround51
        }
        let defaultBitrate = quality.defaultCompressedBitrateBps(for: fallbackLayout) ?? 0
        guard let budgetBps, budgetBps > 0 else { return defaultBitrate }
        let floor = minimumAACBitrate(channels: channels)
        return max(floor, min(defaultBitrate, roundedAACBitrate(budgetBps)))
    }

    static func minimumAACBitrate(channels: Int) -> Int {
        switch channels {
        case 1:
            40_000
        case 2:
            64_000
        default:
            160_000
        }
    }

    static func roundedAACBitrate(_ bitrateBps: Int) -> Int {
        let step = 8_000
        let clamped = max(step, bitrateBps)
        return max(step, (clamped / step) * step)
    }
}

#endif
