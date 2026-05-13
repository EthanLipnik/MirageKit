//
//  StreamBitrateContractTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Stream Bitrate Contract")
struct StreamBitrateContractTests {
    @Test("Standard streams keep the requested bitrate at startup")
    func standardStreamsKeepRequestedBitrateAtStartup() async {
        let context = makeContext(bitrate: 120_000_000)
        let settings = await context.encoderSettings

        #expect(settings.bitrate == 120_000_000)
        #expect(await context.requestedTargetBitrate == 120_000_000)
    }

    @Test("Adaptation ceilings clamp startup bitrate without host-side degradation")
    func adaptationCeilingsClampStartupBitrateWithoutHostSideDegradation() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 100_000_000
        )
        let settings = await context.encoderSettings

        #expect(settings.bitrate == 100_000_000)
        #expect(await context.requestedTargetBitrate == 100_000_000)
    }

    private func makeContext(
        bitrate: Int,
        bitrateAdaptationCeiling: Int? = nil
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 77,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: config,
            runtimeQualityAdjustmentEnabled: true,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling
        )
    }
}
#endif
