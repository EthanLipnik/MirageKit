//
//  AudioDecodePipelineTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Off-main client audio decode pipeline coverage.
//

@testable import MirageKitClient
import AVFAudio
import Foundation
import MirageKit
import Testing

private final class TestAudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioBuffer
    private var hasProvidedInput = false

    init(buffer: AVAudioBuffer) {
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

@Suite("Client Audio Decode Pipeline")
struct AudioDecodePipelineTests {
    @Test("Ingest preserves timestamp ordering across out-of-order packets")
    func preservesTimestampOrdering() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)
        let payload = Self.makePCM16StereoPayload(sampleCount: 4_800)

        let newer = Self.makeHeader(
            frameNumber: 20,
            timestamp: 2_000,
            payloadSize: payload.count
        )
        let older = Self.makeHeader(
            frameNumber: 19,
            timestamp: 1_000,
            payloadSize: payload.count
        )

        let firstBatch = await pipeline.ingestPacket(
            header: newer,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(firstBatch.isEmpty)

        let secondBatch = await pipeline.ingestPacket(
            header: older,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(secondBatch.count == 2)
        #expect(secondBatch[0].timestampNs == 1_000)
        #expect(secondBatch[1].timestampNs == 2_000)
    }

    @Test("Ingest emits decoded frames only when a full frame is assembled")
    func emitsDecodedFramesOnlyAfterFullAssembly() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0)
        let fragmentPayload = Data(repeating: 0x12, count: 960)

        let firstFragment = Self.makeHeader(
            frameNumber: 44,
            timestamp: 4_400,
            fragmentIndex: 0,
            fragmentCount: 2,
            payloadSize: fragmentPayload.count,
            frameByteCount: fragmentPayload.count * 2
        )
        let secondFragment = Self.makeHeader(
            frameNumber: 44,
            timestamp: 4_400,
            fragmentIndex: 1,
            fragmentCount: 2,
            payloadSize: fragmentPayload.count,
            frameByteCount: fragmentPayload.count * 2
        )

        let firstBatch = await pipeline.ingestPacket(
            header: firstFragment,
            payload: fragmentPayload,
            targetChannelCount: 2
        )
        #expect(firstBatch.isEmpty)

        let secondBatch = await pipeline.ingestPacket(
            header: secondFragment,
            payload: fragmentPayload,
            targetChannelCount: 2
        )
        #expect(secondBatch.count == 1)
        #expect(secondBatch[0].frameCount > 0)
    }

    @Test("Reset drops buffered state and decodes subsequent packets cleanly")
    func resetDropsBufferedState() async {
        let pipeline = ClientAudioDecodePipeline(startupBufferSeconds: 0.150)
        let payload = Self.makePCM16StereoPayload(sampleCount: 4_800)
        let header = Self.makeHeader(frameNumber: 10, timestamp: 1_000, payloadSize: payload.count)

        let initialBatch = await pipeline.ingestPacket(
            header: header,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(initialBatch.isEmpty)

        await pipeline.reset()

        let afterResetBatch = await pipeline.ingestPacket(
            header: header,
            payload: payload,
            targetChannelCount: 2
        )
        #expect(afterResetBatch.isEmpty)
    }

    @Test("AAC LC packet decodes to PCM frames")
    func aacPacketDecodesToPCMFrames() async throws {
        let decoder = AudioDecoder()
        let frame = try Self.makeAACFrame()

        let decoded = await decoder.decode(frame, targetChannelCount: 2)

        let decodedFrame = try #require(decoded)
        #expect(decodedFrame.sampleRate == 48_000)
        #expect(decodedFrame.channelCount == 2)
        #expect(decodedFrame.frameCount > 0)
        #expect(!decodedFrame.pcmData.isEmpty)
    }

    @Test("AAC LC stream continues decoding after priming packet")
    func aacStreamContinuesDecodingAfterPrimingPacket() async throws {
        let decoder = AudioDecoder()
        let frames = try Self.makeAACFrames(count: 8)
        var decodedFrames: [DecodedPCMFrame] = []

        for frame in frames {
            if let decoded = await decoder.decode(frame, targetChannelCount: 2) {
                decodedFrames.append(decoded)
            }
        }

        #expect(decodedFrames.count == frames.count)
        let audibleDecodedFrameCount = decodedFrames.filter { Self.decodedFrameRMS($0) > 0.001 }.count
        #expect(audibleDecodedFrameCount >= 4)
    }

    private static func makeHeader(
        frameNumber: UInt32,
        timestamp: UInt64,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        payloadSize: Int,
        frameByteCount: Int? = nil
    ) -> AudioPacketHeader {
        AudioPacketHeader(
            codec: .pcm16LE,
            streamID: 7,
            sequenceNumber: frameNumber,
            timestamp: timestamp,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: UInt16(payloadSize),
            frameByteCount: UInt32(frameByteCount ?? payloadSize),
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 4_800,
            checksum: 0
        )
    }

    private static func makePCM16StereoPayload(sampleCount: Int) -> Data {
        let clampedSampleCount = max(1, sampleCount)
        var payload = Data()
        payload.reserveCapacity(clampedSampleCount * 2 * MemoryLayout<Int16>.size)
        for sampleIndex in 0 ..< clampedSampleCount {
            var left = Int16((sampleIndex % 255) - 127).littleEndian
            var right = Int16(127 - (sampleIndex % 255)).littleEndian
            withUnsafeBytes(of: &left) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &right) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    private static func makeAACFrame() throws -> AudioEncodedFrame {
        let frames = try makeAACFrames(count: 1)
        return try #require(frames.first)
    }

    private static func makeAACFrames(count: Int) throws -> [AudioEncodedFrame] {
        let sampleRate = 48_000.0
        let channelCount: AVAudioChannelCount = 2
        let frameCount = 1_024
        let bitrate = 192_000
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ))
        let outputFormat = try #require(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRateKey: bitrate,
        ]))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))

        var frames: [AudioEncodedFrame] = []
        frames.reserveCapacity(max(0, count))
        for frameNumber in 0 ..< max(0, count) {
            let inputBuffer = try #require(AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ))
            inputBuffer.frameLength = AVAudioFrameCount(frameCount)
            let channelData = try #require(inputBuffer.floatChannelData)
            for frameIndex in 0 ..< frameCount {
                let sampleIndex = frameNumber * frameCount + frameIndex
                let phase = Float(sampleIndex) / Float(frameCount)
                channelData[0][frameIndex] = sin(phase * .pi * 2) * 0.25
                channelData[1][frameIndex] = cos(phase * .pi * 2) * 0.25
            }

            let compressedBuffer = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: AVAudioPacketCount(frameCount),
                maximumPacketSize: max(512, converter.maximumOutputPacketSize)
            )
            let inputProvider = TestAudioConverterInputProvider(buffer: inputBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: compressedBuffer, error: &conversionError) { _, outStatus in
                inputProvider.provideInput(outStatus: outStatus)
            }
            #expect(conversionError == nil)
            #expect(status == .haveData || status == .inputRanDry || status == .endOfStream)
            let byteLength = Int(compressedBuffer.byteLength)
            #expect(byteLength > 0)
            let payload = Data(bytes: compressedBuffer.data, count: max(0, byteLength))
            frames.append(AudioEncodedFrame(
                frameNumber: UInt32(frameNumber + 1),
                timestampNs: UInt64(frameNumber) * UInt64(frameCount) * 1_000_000_000 / UInt64(Int(sampleRate)),
                codec: .aacLC,
                sampleRate: Int(sampleRate),
                channelCount: Int(channelCount),
                samplesPerFrame: frameCount,
                payload: payload
            ))
        }
        return frames
    }

    private static func decodedFrameRMS(_ frame: DecodedPCMFrame) -> Double {
        frame.pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { partial, sample in
                partial + Double(sample * sample)
            }
            return sqrt(sum / Double(samples.count))
        }
    }
}
