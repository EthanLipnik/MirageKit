//
//  MirageAudioConfigurationDesktopModeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKit
import Testing

@Suite("MirageAudioConfiguration Desktop Mode Policy")
struct MirageAudioConfigurationDesktopModeTests {
    @Test("Mirrored desktop preserves the requested audio configuration")
    func mirroredDesktopPreservesAudioConfiguration() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .surround51,
            quality: .low
        )

        let resolved = configuration.resolvedForDesktopStreamMode(.unified)

        #expect(resolved == configuration)
    }

    @Test("Secondary desktop disables host audio streaming")
    func secondaryDesktopDisablesAudioStreaming() {
        let configuration = MirageAudioConfiguration(
            enabled: true,
            channelLayout: .surround51,
            quality: .high
        )

        let resolved = configuration.resolvedForDesktopStreamMode(.secondary)

        #expect(resolved.enabled == false)
        #expect(resolved.channelLayout == configuration.channelLayout)
        #expect(resolved.quality == configuration.quality)
    }
}
