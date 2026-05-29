//
//  MirageAudioConfigurationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("Mirage Audio Configuration")
struct MirageAudioConfigurationTests {
    @Test("Decoding old audio configuration defaults adaptive fields")
    func decodingOldAudioConfigurationDefaultsAdaptiveFields() throws {
        let data = Data(
            """
            {
              "enabled": true,
              "channelLayout": "stereo",
              "quality": "high"
            }
            """.utf8
        )

        let configuration = try JSONDecoder().decode(MirageAudioConfiguration.self, from: data)

        #expect(configuration.enabled)
        #expect(configuration.channelLayout == .stereo)
        #expect(configuration.quality == .high)
        #expect(configuration.compressedBitrateBps == nil)
        #expect(configuration.compressedBitrateCeilingBps == nil)
        #expect(!configuration.adaptiveCompressionEnabled)
    }

    @Test("Lossless audio ignores compressed adaptive budget")
    func losslessAudioIgnoresCompressedAdaptiveBudget() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .lossless,
            compressedBitrateBps: 96_000,
            compressedBitrateCeilingBps: 192_000,
            adaptiveCompressionEnabled: true
        )

        #expect(configuration.quality == .lossless)
        #expect(configuration.compressedBitrateBps == nil)
        #expect(configuration.compressedBitrateCeilingBps == nil)
        #expect(!configuration.adaptiveCompressionEnabled)
    }

    @Test("Compressed audio budget is floored by channel layout")
    func compressedAudioBudgetIsFlooredByChannelLayout() {
        let stereo = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 16_000,
            adaptiveCompressionEnabled: true
        )
        let surround = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .surround51,
            quality: .high,
            compressedBitrateBps: 64_000,
            adaptiveCompressionEnabled: true
        )

        #expect(stereo.compressedBitrateBps == 64_000)
        #expect(surround.compressedBitrateBps == 160_000)
    }

    @Test("Compressed audio ceiling is floored by channel layout")
    func compressedAudioCeilingIsFlooredByChannelLayout() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 96_000,
            compressedBitrateCeilingBps: 48_000,
            adaptiveCompressionEnabled: true
        )

        #expect(configuration.compressedBitrateBps == 96_000)
        #expect(configuration.compressedBitrateCeilingBps == 96_000)
    }
}
