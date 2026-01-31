//
//  AudioDecoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio decoding for client playback.
//

import Foundation
import AVFoundation

final class AudioDecoder {
    private let config: AudioConfigMessage
    private let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat?
    private let converter: AVAudioConverter?

    var playbackFormat: AVAudioFormat { outputFormat }

    init?(config: AudioConfigMessage) {
        self.config = config
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(config.sampleRate),
            channels: AVAudioChannelCount(config.channelCount),
            interleaved: true
        ) else {
            return nil
        }
        self.outputFormat = outputFormat

        if config.codec == .aacLc {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: config.sampleRate,
                AVNumberOfChannelsKey: config.channelCount
            ]
            let inputFormat = AVAudioFormat(settings: settings)
            self.inputFormat = inputFormat
            if let inputFormat {
                self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            } else {
                self.converter = nil
            }
        } else {
            self.inputFormat = nil
            self.converter = nil
        }
    }

    func decode(_ payload: Data) -> AVAudioPCMBuffer? {
        switch config.codec {
        case .pcmFloat32:
            return Self.pcmBuffer(from: payload, format: outputFormat)
        case .aacLc:
            return decodeAAC(payload)
        }
    }

    private func decodeAAC(_ payload: Data) -> AVAudioPCMBuffer? {
        guard let inputFormat, let converter else { return nil }
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: payload.count
        )

        payload.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                memcpy(compressedBuffer.data, baseAddress, payload.count)
            }
        }
        compressedBuffer.byteLength = UInt32(payload.count)
        compressedBuffer.packetCount = 1

        let frameCapacity = AVAudioFrameCount(1_024)
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
            return compressedBuffer
        }

        if status == .error {
            MirageLogger.error(.client, "AAC decode failed: \(error?.localizedDescription ?? "Unknown")")
            return nil
        }

        return outputBuffer
    }

    private static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let mData = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        data.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                memcpy(mData, baseAddress, data.count)
            }
        }
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(data.count)

        return buffer
    }
}
