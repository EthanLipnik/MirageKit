//
//  MirageBitrateQualityMapperTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/3/26.
//

import MirageMedia
import Testing

@Suite("Mirage Bitrate Quality Mapper")
struct MirageBitrateQualityMapperTests {
    @Test("High refresh uses sixty hertz quality reference")
    func highRefreshUsesSixtyHertzQualityReference() {
        let sixty = MirageMedia.MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 96_000_000,
            width: 2752,
            height: 2064,
            frameRate: 60
        )
        let oneTwenty = MirageMedia.MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 96_000_000,
            width: 2752,
            height: 2064,
            frameRate: 120
        )

        #expect(oneTwenty.frameQuality == sixty.frameQuality)
        #expect(oneTwenty.keyframeQuality == sixty.keyframeQuality)
    }

    @Test("High refresh target bitrate uses sixty hertz quality reference")
    func highRefreshTargetBitrateUsesSixtyHertzQualityReference() throws {
        let sixty = try #require(
            MirageMedia.MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: 0.60,
                width: 2752,
                height: 2064,
                frameRate: 60,
                maxBitrateBps: 180_000_000
            )
        )
        let oneTwenty = try #require(
            MirageMedia.MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: 0.60,
                width: 2752,
                height: 2064,
                frameRate: 120,
                maxBitrateBps: 180_000_000
            )
        )

        #expect(oneTwenty == sixty)
    }

    @Test("High refresh no longer applies a quality scale")
    func highRefreshNoLongerAppliesQualityScale() {
        #expect(MirageMedia.MirageBitrateQualityMapper.frameRateScale(frameRate: 120, bpp: 0.05) == 1.0)
        #expect(MirageMedia.MirageBitrateQualityMapper.frameRateScale(frameRate: 90, bpp: 0.05) == 1.0)
        #expect(MirageMedia.MirageBitrateQualityMapper.frameRateScale(frameRate: 60, bpp: 0.05) == 1.0)
    }
}
