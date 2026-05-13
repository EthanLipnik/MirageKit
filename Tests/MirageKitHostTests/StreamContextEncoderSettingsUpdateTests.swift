//
//  StreamContextEncoderSettingsUpdateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Stream Context Encoder Settings Updates")
struct StreamContextEncoderSettingsUpdateTests {
    @Test("Capture configuration follows encoder pixel-format fallback")
    func captureConfigurationFollowsEncoderPixelFormatFallback() {
        let requested = MirageEncoderConfiguration.highQuality.withOverrides(colorDepth: .ultra)
        let resolved = requested.withInternalOverrides(pixelFormat: .p010)

        #expect(requested.pixelFormat == .xf44)
        #expect(resolved.pixelFormat == .p010)
        #expect(resolved.colorDepth == .pro)
        #expect(resolved.bitDepth == .tenBit)
        #expect(resolved.colorSpace == .displayP3)
        #expect(resolved.bitrate == requested.bitrate)
        #expect(resolved.targetFrameRate == requested.targetFrameRate)
    }
}
#endif
