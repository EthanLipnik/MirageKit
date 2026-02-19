//
//  HEVCEncoderRateLimitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/19/26.
//
//  Coverage for encoder data-rate limit budget calculations.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("HEVC Encoder Rate Limits")
struct HEVCEncoderRateLimitTests {
    @Test("120 Hz data-rate limit uses window budget bytes")
    func highRefreshBudget() {
        let limit = HEVCEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 120
        )

        #expect(limit.windowSeconds == 0.25)
        #expect(limit.bytes == 2_500_000)
    }

    @Test("60 Hz data-rate limit uses window budget bytes")
    func standardRefreshBudget() {
        let limit = HEVCEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 60
        )

        #expect(limit.windowSeconds == 0.5)
        #expect(limit.bytes == 5_000_000)
    }

    @Test("Frame-rate update path refreshes bitrate window selection inputs")
    func frameRateUpdateRefreshesRateLimitInputs() async {
        let encoder = HEVCEncoder(
            configuration: MirageEncoderConfiguration(
                targetFrameRate: 60,
                bitrate: 80_000_000
            )
        )

        #expect(await encoder.configuration.targetFrameRate == 60)
        await encoder.updateFrameRate(120)
        #expect(await encoder.configuration.targetFrameRate == 120)

        let targetBitrate = await encoder.configuration.bitrate ?? 0
        let refreshedLimit = HEVCEncoder.dataRateLimit(
            targetBitrateBps: targetBitrate,
            targetFrameRate: await encoder.configuration.targetFrameRate
        )
        #expect(refreshedLimit.windowSeconds == 0.25)
        #expect(refreshedLimit.bytes == 2_500_000)
    }
}
#endif
