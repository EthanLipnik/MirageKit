//
//  VideoEncoderRateLimitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/19/26.
//
//  Coverage for encoder data-rate limit budget calculations.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing
import VideoToolbox

@Suite("HEVC Encoder Rate Limit")
struct HEVCEncoderRateLimitTests {

    @Test("Frame-rate update path refreshes bitrate window selection inputs")
    func frameRateUpdateRefreshesRateLimitInputs() async {
        let encoder = VideoEncoder(
            configuration: MirageEncoderConfiguration(
                targetFrameRate: 60,
                bitrate: 80_000_000
            )
        )

        #expect(await encoder.configuration.targetFrameRate == 60)
        await encoder.updateFrameRate(120)
        #expect(await encoder.configuration.targetFrameRate == 120)

        let targetBitrate = await encoder.configuration.bitrate ?? 0
        let refreshedLimit = VideoEncoder.dataRateLimit(
            targetBitrateBps: targetBitrate,
            targetFrameRate: await encoder.configuration.targetFrameRate
        )
        #expect(refreshedLimit.windowSeconds == 0.25)
        #expect(refreshedLimit.bytes == 2_500_000)
    }

    @Test("Standard encoder specification keeps baseline hardware requirements for auto latency")
    func standardEncoderSpecificationAutoLatency() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .auto
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency desktop specification enables low-latency rate control")
    func standardLowestLatencyEncoderSpecification() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 2_560,
            height: 1_440,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("Standard lowest-latency desktop specification keeps low-latency rate control at high resolution")
    func standardLowestLatencyHighResDesktopEnablesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 6_016,
            height: 3_384,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("Standard lowest-latency window specification suppresses low-latency rate control at high resolution")
    func standardLowestLatencyHighResWindowSuppressesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 6_016,
            height: 3_384,
            streamKind: .window
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency Ultra window specification enables low-latency rate control")
    func standardLowestLatencyUltraWindowEnablesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 2_560,
            height: 1_440,
            streamKind: .window,
            colorDepth: .ultra
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("Game-mode encoder specification enables low-latency rate control")
    func gameModeEncoderSpecification() {
        let spec = VideoEncoder.encoderSpecification(
            for: .game,
            latencyMode: .auto
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

}
#endif
