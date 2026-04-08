//
//  AudioEncodingMappingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Host audio quality/channel mapping coverage.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Audio Encoding Mapping")
struct AudioEncodingMappingTests {
    @Test("Low quality AAC bitrates by channel count")
    func lowQualityAACMapping() {
        let mono = AudioEncoder.encodingParameters(
            for: MirageAudioConfiguration(enabled: true, channelLayout: .mono, quality: .low)
        )
        #expect(mono.codec == .aacLC)
        #expect(mono.sampleRate == 48_000)
        #expect(mono.channelCount == 1)
        #expect(mono.bitrate == 64_000)

        let stereo = AudioEncoder.encodingParameters(
            for: MirageAudioConfiguration(enabled: true, channelLayout: .stereo, quality: .low)
        )
        #expect(stereo.codec == .aacLC)
        #expect(stereo.channelCount == 2)
        #expect(stereo.bitrate == 96_000)

        let surround = AudioEncoder.encodingParameters(
            for: MirageAudioConfiguration(enabled: true, channelLayout: .surround51, quality: .low)
        )
        #expect(surround.codec == .aacLC)
        #expect(surround.channelCount == 6)
        #expect(surround.bitrate == 256_000)
    }

    @Test("High quality AAC and lossless PCM mapping")
    func highAndLosslessMapping() {
        let highSurround = AudioEncoder.encodingParameters(
            for: MirageAudioConfiguration(enabled: true, channelLayout: .surround51, quality: .high)
        )
        #expect(highSurround.codec == .aacLC)
        #expect(highSurround.sampleRate == 48_000)
        #expect(highSurround.channelCount == 6)
        #expect(highSurround.bitrate == 448_000)

        let losslessStereo = AudioEncoder.encodingParameters(
            for: MirageAudioConfiguration(enabled: true, channelLayout: .stereo, quality: .lossless)
        )
        #expect(losslessStereo.codec == .pcm16LE)
        #expect(losslessStereo.sampleRate == 48_000)
        #expect(losslessStereo.channelCount == 2)
        #expect(losslessStereo.bitrate == nil)
    }
}
#endif

