//
//  MirageEncoderConfigurationOverrideTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage Encoder Configuration Overrides")
struct MirageEncoderConfigurationOverrideTests {
    @Test("Color space internal override preserves Ultra tier state")
    func colorSpaceOverridePreservesUltraTier() {
        let configuration = MirageEncoderConfiguration(colorDepth: .ultra)
        let overridden = configuration.withInternalOverrides(colorSpace: .displayP3)

        #expect(overridden.colorDepth == .ultra)
        #expect(overridden.bitDepth == .tenBit)
        #expect(overridden.pixelFormat == .xf44)
        #expect(overridden.colorSpace == .displayP3)
    }
}
