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
    @Test("Fixed lowest-latency desktop caps excessive manual bitrate")
    func fixedLowestLatencyDesktopCapsExcessiveManualBitrate() {
        let bitrate = MirageHostService.resolvedDesktopEncoderBitrate(
            requestedBitrate: 300_000_000,
            latencyMode: .lowestLatency,
            allowRuntimeQualityAdjustment: false
        )

        #expect(bitrate == 150_000_000)
    }

    @Test("Adaptive lowest-latency desktop preserves manual bitrate")
    func adaptiveLowestLatencyDesktopPreservesManualBitrate() {
        let bitrate = MirageHostService.resolvedDesktopEncoderBitrate(
            requestedBitrate: 300_000_000,
            latencyMode: .lowestLatency,
            allowRuntimeQualityAdjustment: true
        )

        #expect(bitrate == 300_000_000)
    }

    @Test("Smooth desktop preserves manual bitrate")
    func smoothDesktopPreservesManualBitrate() {
        let bitrate = MirageHostService.resolvedDesktopEncoderBitrate(
            requestedBitrate: 300_000_000,
            latencyMode: .smoothest,
            allowRuntimeQualityAdjustment: false
        )

        #expect(bitrate == 300_000_000)
    }
}
#endif
