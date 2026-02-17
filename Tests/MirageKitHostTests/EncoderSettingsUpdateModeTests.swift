//
//  EncoderSettingsUpdateModeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Coverage for bitrate-only encoder setting update classification.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Encoder Settings Update Mode")
struct EncoderSettingsUpdateModeTests {
    @Test("No change keeps no-op update mode")
    func noChangeClassification() {
        let current = makeConfiguration()
        let updated = makeConfiguration()
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: updated) == .noChange)
    }

    @Test("Bitrate-only change uses bitrate-only mode")
    func bitrateOnlyClassification() {
        let current = makeConfiguration()
        let updated = current.withOverrides(bitrate: 250_000_000)
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: updated) == .bitrateOnly)
    }

    @Test("Bit depth change uses full reconfiguration")
    func bitDepthRequiresFullReconfiguration() {
        let current = makeConfiguration()

        let bitDepthChange = current.withOverrides(bitDepth: .eightBit)
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: bitDepthChange) == .fullReconfiguration)
    }

    private func makeConfiguration() -> MirageEncoderConfiguration {
        MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            bitDepth: .tenBit,
            bitrate: 600_000_000
        )
    }
}
#endif
