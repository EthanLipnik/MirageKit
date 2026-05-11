//
//  AudioDecoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Audio frame decode and downmix helpers for playback.
//

@preconcurrency import AVFAudio
import AudioToolbox
import Foundation
import MirageKit

struct DecodedPCMFrame: Sendable {
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let timestampNs: UInt64
    let pcmData: Data

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(max(0, frameCount)) / Double(sampleRate)
    }
}

actor AudioDecoder {
    private final class ConverterInputProvider: @unchecked Sendable {
        private let buffer: AVAudioBuffer
        private var didProvideInput = false

        init(buffer: AVAudioBuffer) {
            self.buffer = buffer
        }

        func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    private struct ConverterKey: Hashable {
        let codec: MirageAudioCodec
        let inputSampleRate: Int
        let inputChannels: Int
        let outputChannels: Int
    }

    private var converters: [ConverterKey: AVAudioConverter] = [:]

    func reset() {
        converters.removeAll()
    }

    func decode(_ frame: AudioEncodedFrame, targetChannelCount: Int) -> DecodedPCMFrame? {
        let outputChannelCount = max(1, min(targetChannelCount, frame.channelCount))
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(outputChannelCount),
            interleaved: true
        ) else {
            return nil
        }

        let outputBuffer: AVAudioPCMBuffer? = switch frame.codec {
        case .aacLC:
            decodeAAC(frame, outputFormat: outputFormat, outputChannelCount: outputChannelCount)
        case .pcm16LE:
            decodePCM16(frame, outputFormat: outputFormat, outputChannelCount: outputChannelCount)
        }

        guard let outputBuffer else { return nil }
        guard outputBuffer.frameLength > 0 else { return nil }
        let bufferList = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
        guard let firstBuffer = bufferList.first,
              let mData = firstBuffer.mData,
              firstBuffer.mDataByteSize > 0 else {
            return nil
        }

        let byteCount = Int(firstBuffer.mDataByteSize)
        let pcmData = Data(bytes: mData, count: byteCount)
        return DecodedPCMFrame(
            sampleRate: frame.sampleRate,
            channelCount: outputChannelCount,
            frameCount: Int(outputBuffer.frameLength),
            timestampNs: frame.timestampNs,
            pcmData: pcmData
        )
    }

    private func decodeAAC(
        _ frame: AudioEncodedFrame,
        outputFormat: AVAudioFormat,
        outputChannelCount: Int
    ) -> AVAudioPCMBuffer? {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: frame.sampleRate,
            AVNumberOfChannelsKey: frame.channelCount,
        ]
        guard let inputFormat = AVAudioFormat(settings: settings) else { return nil }

        let key = ConverterKey(
            codec: .aacLC,
            inputSampleRate: frame.sampleRate,
            inputChannels: frame.channelCount,
            outputChannels: outputChannelCount
        )
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            converters[key] = created
            converter = created
        }

        let packetCapacity: AVAudioPacketCount = 1
        let maximumPacketSize = max(frame.payload.count, converter.maximumOutputPacketSize)
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: maximumPacketSize
        )
        compressedBuffer.packetCount = 1
        compressedBuffer.byteLength = UInt32(frame.payload.count)
        frame.payload.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            compressedBuffer.data.copyMemory(from: baseAddress, byteCount: frame.payload.count)
        }
        if let packetDescriptions = compressedBuffer.packetDescriptions {
            packetDescriptions[0].mStartOffset = 0
            packetDescriptions[0].mDataByteSize = UInt32(frame.payload.count)
            packetDescriptions[0].mVariableFramesInPacket = 0
        }

        let estimatedFrames = max(frame.samplesPerFrame * 2, 2048)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            return nil
        }

        let inputProvider = ConverterInputProvider(buffer: compressedBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }

        guard conversionError == nil else { return nil }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream else { return nil }
        return outputBuffer
    }

    private func decodePCM16(
        _ frame: AudioEncodedFrame,
        outputFormat: AVAudioFormat,
        outputChannelCount: Int
    ) -> AVAudioPCMBuffer? {
        let inputChannelCount = max(1, frame.channelCount)
        let bytesPerFrame = MemoryLayout<Int16>.size * inputChannelCount
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = frame.payload.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(inputChannelCount),
            interleaved: true
        ) else {
            return nil
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        let inputBufferList = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        guard let firstBuffer = inputBufferList.first,
              let destination = firstBuffer.mData else {
            return nil
        }
        frame.payload.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            destination.copyMemory(from: sourceBase, byteCount: min(Int(firstBuffer.mDataByteSize), frame.payload.count))
        }

        let key = ConverterKey(
            codec: .pcm16LE,
            inputSampleRate: frame.sampleRate,
            inputChannels: inputChannelCount,
            outputChannels: outputChannelCount
        )
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            converters[key] = created
            converter = created
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(max(frameCount, frame.samplesPerFrame))
        ) else {
            return nil
        }

        let inputProvider = ConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }

        guard conversionError == nil else { return nil }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream else { return nil }
        return outputBuffer
    }
}
