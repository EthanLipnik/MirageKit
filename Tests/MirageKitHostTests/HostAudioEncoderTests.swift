//
//  HostAudioEncoderTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/20/26.
//
//  Host audio encoder compatibility coverage.
//

#if os(macOS)
@testable import MirageKitClient
@testable import MirageKitHost
import CoreMedia
import Foundation
import MirageKit
import MirageMedia
import Testing

@Suite("Host Audio Encoder")
    struct HostAudioEncoderTests {
    @Test("Compressed AAC encoder does not fall back to PCM")
    func compressedAACEncoderDoesNotFallBackToPCM() async {
        let encoder = AudioEncoder(
            audioConfiguration: MirageAudioConfiguration(
                enabled: true,
                channelLayout: .stereo,
                quality: .high,
                compressedBitrateBps: 192_000,
                adaptiveCompressionEnabled: true
            )
        )
        let captured = Self.makeCapturedFloatBuffer(frameCount: 4_800)

        let encodedFrames = await encoder.encode(captured)

        #expect(!encodedFrames.isEmpty)
        #expect(encodedFrames.allSatisfy { $0.codec == .aacLC })
        #expect(encodedFrames.allSatisfy { $0.codec != .pcm16LE })
    }

    @Test("Lossless encoder uses explicit PCM")
    func losslessEncoderUsesExplicitPCM() async {
        let encoder = AudioEncoder(
            audioConfiguration: MirageAudioConfiguration(
                enabled: true,
                channelLayout: .stereo,
                quality: .lossless
            )
        )
        let captured = Self.makeCapturedFloatBuffer(frameCount: 480)

        let encodedFrames = await encoder.encode(captured)

        #expect(encodedFrames.count == 1)
        #expect(encodedFrames.first?.codec == .pcm16LE)
    }

    @Test("AAC encoder splits multi-packet output into decodable frames")
    func aacEncoderSplitsMultiPacketOutputIntoDecodableFrames() async throws {
        let encoder = AudioEncoder(
            audioConfiguration: MirageAudioConfiguration(
                enabled: true,
                channelLayout: .stereo,
                quality: .high,
                compressedBitrateBps: 192_000,
                adaptiveCompressionEnabled: false
            )
        )
        let captured = Self.makeCapturedFloatBuffer(frameCount: 4_800)

        let encodedFrames = await encoder.encode(captured)

        #expect(encodedFrames.count > 1)
        #expect(encodedFrames.allSatisfy { $0.codec == .aacLC })
        #expect(encodedFrames.allSatisfy { $0.samplesPerFrame <= 1_024 })
        #expect(encodedFrames.map(\.timestampNs) == encodedFrames.map(\.timestampNs).sorted())

        let decoder = AudioDecoder()
        var decodedCount = 0
        for (index, encoded) in encodedFrames.enumerated() {
            let clientFrame = AudioEncodedFrame(
                frameNumber: UInt32(index),
                timestampNs: encoded.timestampNs,
                codec: encoded.codec,
                sampleRate: encoded.sampleRate,
                channelCount: encoded.channelCount,
                samplesPerFrame: encoded.samplesPerFrame,
                payload: encoded.data
            )
            if let decoded = await decoder.decode(clientFrame, targetChannelCount: 2) {
                #expect(decoded.frameCount > 0)
                decodedCount += 1
            }
        }
        #expect(decodedCount == encodedFrames.count)
    }

    private static func makeCapturedFloatBuffer(frameCount: Int, channelCount: Int = 2) -> CapturedAudioBuffer {
        let sampleRate = 48_000.0
        var data = Data()
        data.reserveCapacity(frameCount * channelCount * MemoryLayout<Float32>.size)
        for frameIndex in 0 ..< frameCount {
            let phase = Float(frameIndex) / Float(max(1, frameCount))
            for channelIndex in 0 ..< channelCount {
                var sample = sin((phase + Float(channelIndex) * 0.05) * .pi * 16) * 0.25
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
        }
        return CapturedAudioBuffer(
            data: data,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            bitsPerChannel: 32,
            isFloat: true,
            isInterleaved: true,
            presentationTime: CMTime(seconds: 2, preferredTimescale: 1_000_000_000)
        )
    }
}
#endif
