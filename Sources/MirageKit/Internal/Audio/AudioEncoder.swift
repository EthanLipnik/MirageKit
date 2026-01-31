//
//  AudioEncoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio encoding pipeline.
//

import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

#if os(macOS)
final class AudioEncoder {
    private let baseConfiguration: MirageAudioConfiguration
    private var lastConfig: MirageAudioConfiguration?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var lastTimestamp: UInt64?
    private var lastChannelWarning: (requested: Int, input: Int)?
    private var pendingPCMBuffer: AVAudioPCMBuffer?
    private var lastAACEmptyLogTime: CFAbsoluteTime = 0
    private var aacFrameSize: AVAudioFrameCount = 1_024
    private var lastAACBufferingLogTime: CFAbsoluteTime = 0

    init(baseConfiguration: MirageAudioConfiguration) {
        self.baseConfiguration = baseConfiguration
    }

    func encode(sampleBuffer: CMSampleBuffer) -> [AudioEncodedFrame] {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return [] }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return [] }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
           asbd.pointee.mFormatID != kAudioFormatLinearPCM {
            MirageLogger.error(.host, "Unsupported audio format: \(fourCC(asbd.pointee.mFormatID))")
            return []
        }

        let resolvedConfig = resolveConfiguration(using: inputFormat)
        let flags: AudioFlags = resolvedConfigMatchesLast(resolvedConfig) ? [] : [.discontinuity]

        if self.inputFormat == nil || self.outputFormat == nil || !resolvedConfigMatchesLast(resolvedConfig) {
            self.inputFormat = inputFormat
            self.outputFormat = makeOutputFormat(for: resolvedConfig)
            if let outputFormat = self.outputFormat {
                self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            }
            self.lastConfig = resolvedConfig
            self.pendingPCMBuffer = nil
        }

        guard let inputBuffer = Self.makePCMBuffer(from: sampleBuffer, format: inputFormat) else { return [] }
        if resolvedConfig.codec == .aacLc, aacFrameSize == 1_024 {
            let sampleFrames = inputBuffer.frameLength
            if sampleFrames > 0, sampleFrames != 1_024 {
                aacFrameSize = sampleFrames
                MirageLogger.host("AAC frame size adjusted to \(sampleFrames) frames")
            }
        }
        let timeSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        var timestamp = timeSeconds.isFinite ? UInt64(timeSeconds * 1_000_000_000) : (lastTimestamp ?? 0)
        if let lastTimestamp, timestamp <= lastTimestamp {
            let durationSeconds = Double(inputBuffer.frameLength) / Double(max(1, resolvedConfig.sampleRate))
            let durationNanos = UInt64(durationSeconds * 1_000_000_000)
            timestamp = lastTimestamp &+ durationNanos
        }
        lastTimestamp = timestamp

        if resolvedConfig.codec == .pcmFloat32 {
            guard let outputBuffer = convertPCMBuffer(inputBuffer) else { return [] }
            let data = Self.dataFromPCMBuffer(outputBuffer)
            return [AudioEncodedFrame(data: data, timestamp: timestamp, flags: flags, config: resolvedConfig)]
        }

        guard let aacInput = prepareAACInputBuffer(from: inputBuffer) else { return [] }
        guard let packets = convertToAACPackets(aacInput) else { return [] }
        let packetDuration = UInt64((1_024.0 / Double(resolvedConfig.sampleRate)) * 1_000_000_000)

        return packets.enumerated().map { index, packet in
            let packetTimestamp = timestamp &+ (packetDuration &* UInt64(index))
            let packetFlags: AudioFlags = index == 0 ? flags : []
            return AudioEncodedFrame(data: packet, timestamp: packetTimestamp, flags: packetFlags, config: resolvedConfig)
        }
    }

    private func resolvedConfigMatchesLast(_ config: MirageAudioConfiguration) -> Bool {
        guard let lastConfig else { return false }
        return lastConfig.channelCount == config.channelCount &&
            lastConfig.sampleRate == config.sampleRate &&
            lastConfig.codec == config.codec &&
            lastConfig.channelLayout == config.channelLayout &&
            lastConfig.quality == config.quality
    }

    private func resolveConfiguration(using inputFormat: AVAudioFormat) -> MirageAudioConfiguration {
        var config = baseConfiguration
        let inputChannelCount = Int(inputFormat.channelCount)

        switch config.mode {
        case .full:
            config.codec = .pcmFloat32
            config.sampleRate = 48_000
            config.channelCount = inputChannelCount
            config.channelLayout = .source
            config.bitrate = nil
        case .mono, .stereo, .surround:
            let desiredChannels = max(1, config.channelCount)
            let resolvedChannels = min(desiredChannels, inputChannelCount)
            config.sampleRate = 48_000
            config.channelCount = resolvedChannels
            config.channelLayout = resolvedChannels >= 6 ? .surround5_1 : (resolvedChannels == 1 ? .mono : .stereo)
            config.codec = .aacLc
            config.bitrate = MirageAudioConfiguration.aacBitrate(for: config.quality, channelCount: resolvedChannels)
            if resolvedChannels != desiredChannels {
                if lastChannelWarning?.requested != desiredChannels || lastChannelWarning?.input != inputChannelCount {
                    MirageLogger.host("Audio downmix: requested \(desiredChannels)ch, input \(inputChannelCount)ch, using \(resolvedChannels)ch")
                    lastChannelWarning = (requested: desiredChannels, input: inputChannelCount)
                }
            }
        case .off:
            break
        }

        return config
    }

    private func makeOutputFormat(for config: MirageAudioConfiguration) -> AVAudioFormat? {
        if config.codec == .pcmFloat32 {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(config.sampleRate),
                channels: AVAudioChannelCount(config.channelCount),
                interleaved: true
            )
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: config.sampleRate,
            AVNumberOfChannelsKey: config.channelCount,
            AVEncoderBitRateKey: config.bitrate ?? 192_000
        ]
        return AVAudioFormat(settings: settings)
    }

    private func convertPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat else { return buffer }
        if buffer.format.sampleRate == outputFormat.sampleRate,
           buffer.format.channelCount == outputFormat.channelCount,
           buffer.format.commonFormat == outputFormat.commonFormat,
           buffer.format.isInterleaved == outputFormat.isInterleaved {
            return buffer
        }

        guard let converter else { return nil }
        let frameCapacity = AVAudioFrameCount(buffer.frameLength)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            MirageLogger.error(.host, "PCM conversion failed: \(error?.localizedDescription ?? "Unknown")")
            return nil
        }
        return outputBuffer
    }

    private func convertToAACPackets(_ buffer: AVAudioPCMBuffer) -> [Data]? {
        guard let outputFormat, let converter else { return nil }
        let maxPacketSize = converter.maximumOutputPacketSize
        let packetCapacity = max(1, AVAudioPacketCount((Double(buffer.frameLength) / 1_024.0).rounded(.up)))
        let compressedBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: maxPacketSize
        )

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: compressedBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            MirageLogger.error(.host, "AAC conversion failed: \(error?.localizedDescription ?? "Unknown")")
            return nil
        }

        let packetCount = Int(compressedBuffer.packetCount)
        guard packetCount > 0 else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastAACEmptyLogTime > 2.0 {
                MirageLogger.error(.host, "AAC conversion produced no packets (frames=\(buffer.frameLength))")
                lastAACEmptyLogTime = now
            }
            return nil
        }

        if packetCount == 1 || compressedBuffer.packetDescriptions == nil {
            let byteCount = Int(compressedBuffer.byteLength)
            guard byteCount > 0 else { return nil }
            return [Data(bytes: compressedBuffer.data, count: byteCount)]
        }

        var packets: [Data] = []
        packets.reserveCapacity(packetCount)

        let descriptions = UnsafeBufferPointer(start: compressedBuffer.packetDescriptions, count: packetCount)
        for description in descriptions {
            let byteCount = Int(description.mDataByteSize)
            guard byteCount > 0 else { continue }
            let startOffset = Int(description.mStartOffset)
            let packetPointer = compressedBuffer.data.advanced(by: startOffset)
            packets.append(Data(bytes: packetPointer, count: byteCount))
        }

        return packets
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount
        let targetBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: targetBuffers.unsafeMutablePointer
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Audio PCM copy failed: \(status)")
            return nil
        }

        return pcmBuffer
    }

    private static func dataFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Data {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let dataPointer = audioBuffer.mData else { return Data() }
        return Data(bytes: dataPointer, count: Int(audioBuffer.mDataByteSize))
    }

    private func prepareAACInputBuffer(from inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard inputBuffer.frameLength > 0 else { return nil }
        if pendingPCMBuffer == nil {
            let capacity = max(inputBuffer.frameLength, aacFrameSize * 2)
            pendingPCMBuffer = AVAudioPCMBuffer(pcmFormat: inputBuffer.format, frameCapacity: capacity)
            pendingPCMBuffer?.frameLength = 0
        }
        guard let pending = pendingPCMBuffer else { return nil }

        let requiredFrames = pending.frameLength + inputBuffer.frameLength
        if pending.frameCapacity < requiredFrames {
            let newCapacity = max(requiredFrames, pending.frameCapacity * 2)
            guard let newBuffer = AVAudioPCMBuffer(pcmFormat: inputBuffer.format, frameCapacity: newCapacity) else { return nil }
            newBuffer.frameLength = pending.frameLength
            copyFrames(from: pending, sourceFrame: 0, to: newBuffer, destFrame: 0, frameCount: pending.frameLength)
            pendingPCMBuffer = newBuffer
        }

        guard let updatedPending = pendingPCMBuffer else { return nil }
        copyFrames(from: inputBuffer, sourceFrame: 0, to: updatedPending, destFrame: updatedPending.frameLength, frameCount: inputBuffer.frameLength)
        updatedPending.frameLength += inputBuffer.frameLength

        guard updatedPending.frameLength >= aacFrameSize else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastAACBufferingLogTime > 2.0 {
                MirageLogger.host("AAC buffering: pending \(updatedPending.frameLength) frames, input \(inputBuffer.frameLength), target \(aacFrameSize)")
                lastAACBufferingLogTime = now
            }
            return nil
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: inputBuffer.format, frameCapacity: aacFrameSize) else { return nil }
        output.frameLength = aacFrameSize
        copyFrames(from: updatedPending, sourceFrame: 0, to: output, destFrame: 0, frameCount: aacFrameSize)
        shiftBufferLeft(updatedPending, by: aacFrameSize)
        return output
    }

    private func copyFrames(
        from source: AVAudioPCMBuffer,
        sourceFrame: AVAudioFrameCount,
        to destination: AVAudioPCMBuffer,
        destFrame: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) {
        guard frameCount > 0 else { return }
        let format = source.format
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let channelCount = Int(format.channelCount)

        if format.isInterleaved {
            let sourceBuffer = source.audioBufferList.pointee.mBuffers
            let destinationBuffer = destination.mutableAudioBufferList.pointee.mBuffers
            guard let srcData = sourceBuffer.mData, let dstData = destinationBuffer.mData else { return }
            let srcOffset = Int(sourceFrame) * bytesPerFrame
            let dstOffset = Int(destFrame) * bytesPerFrame
            let byteCount = Int(frameCount) * bytesPerFrame
            memcpy(dstData.advanced(by: dstOffset), srcData.advanced(by: srcOffset), byteCount)
            destination.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(max(Int(destinationBuffer.mDataByteSize), dstOffset + byteCount))
        } else {
            let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
            let dstList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
            let bytesPerFramePerChannel = bytesPerFrame
            let byteCount = Int(frameCount) * bytesPerFramePerChannel
            for channel in 0..<min(channelCount, srcList.count) {
                guard let srcData = srcList[channel].mData, let dstData = dstList[channel].mData else { continue }
                let srcOffset = Int(sourceFrame) * bytesPerFramePerChannel
                let dstOffset = Int(destFrame) * bytesPerFramePerChannel
                memcpy(dstData.advanced(by: dstOffset), srcData.advanced(by: srcOffset), byteCount)
                dstList[channel].mDataByteSize = UInt32(max(Int(dstList[channel].mDataByteSize), dstOffset + byteCount))
            }
        }
    }

    private func shiftBufferLeft(_ buffer: AVAudioPCMBuffer, by frameCount: AVAudioFrameCount) {
        guard frameCount > 0 else { return }
        guard buffer.frameLength > frameCount else {
            buffer.frameLength = 0
            return
        }

        let remainingFrames = buffer.frameLength - frameCount
        let format = buffer.format
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let channelCount = Int(format.channelCount)

        if format.isInterleaved {
            let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
            guard let data = audioBuffer.mData else { return }
            let srcOffset = Int(frameCount) * bytesPerFrame
            let byteCount = Int(remainingFrames) * bytesPerFrame
            memmove(data, data.advanced(by: srcOffset), byteCount)
            buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        } else {
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytesPerFramePerChannel = bytesPerFrame
            let byteCount = Int(remainingFrames) * bytesPerFramePerChannel
            for channel in 0..<min(channelCount, list.count) {
                guard let data = list[channel].mData else { continue }
                let srcOffset = Int(frameCount) * bytesPerFramePerChannel
                memmove(data, data.advanced(by: srcOffset), byteCount)
                list[channel].mDataByteSize = UInt32(byteCount)
            }
        }

        buffer.frameLength = remainingFrames
    }
}

private func fourCC(_ value: UInt32) -> String {
    var bigEndian = value.bigEndian
    let bytes = withUnsafeBytes(of: &bigEndian) { Array($0) }
    let chars = bytes.map { byte -> Character in
        if byte >= 32 && byte <= 126 {
            return Character(UnicodeScalar(byte))
        }
        return "?"
    }
    return String(chars)
}

private func audioBufferListSize(maximumBuffers: Int) -> Int {
    MemoryLayout<AudioBufferList>.size + (maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
}
#endif
