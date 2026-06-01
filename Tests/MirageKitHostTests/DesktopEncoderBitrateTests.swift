//
//  DesktopEncoderBitrateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Desktop Encoder Bitrate")
struct DesktopEncoderBitrateTests {
    @Test("Desktop encoder honors the user's manual bitrate")
    func desktopEncoderHonorsManualBitrate() {
        // The host must never cap the user's chosen bitrate; it drops frames
        // under load instead. (Custom/adaptive-off owns the tradeoff.)
        let bitrate = MirageHostService.resolvedDesktopEncoderBitrate(
            requestedBitrate: 300_000_000
        )

        #expect(bitrate == 300_000_000)
    }
}
#endif
