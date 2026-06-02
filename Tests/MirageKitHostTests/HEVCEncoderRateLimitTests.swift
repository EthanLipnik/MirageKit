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
        #expect(abs(refreshedLimit.windowSeconds - (2.0 / 120.0)) < 0.0001)
        #expect(refreshedLimit.bytes == 166_667)
    }

    @Test("Rate-limit windows use short two-frame windows at high frame rates")
    func rateLimitWindowsUseShortTwoFrameWindowsAtHighFrameRates() {
        let sixtyFPS = VideoEncoder.dataRateLimit(
            targetBitrateBps: 12_000_000,
            targetFrameRate: 60
        )
        let ninetyFPS = VideoEncoder.dataRateLimit(
            targetBitrateBps: 12_000_000,
            targetFrameRate: 90
        )

        #expect(abs(sixtyFPS.windowSeconds - (2.0 / 60.0)) < 0.0001)
        #expect(sixtyFPS.bytes == 50_000)
        #expect(abs(ninetyFPS.windowSeconds - (2.0 / 90.0)) < 0.0001)
        #expect(ninetyFPS.bytes == 33_333)
    }

    @Test("AWDL rate-limit windows are shorter to avoid encoder-side bursts")
    func awdlRateLimitWindowsAreShorter() {
        let sixtyFPS = VideoEncoder.dataRateLimit(
            targetBitrateBps: 24_000_000,
            targetFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        let oneTwentyFPS = VideoEncoder.dataRateLimit(
            targetBitrateBps: 24_000_000,
            targetFrameRate: 120,
            mediaPathProfile: .awdlRadio
        )

        #expect(sixtyFPS.windowSeconds == 0.15)
        #expect(sixtyFPS.bytes == 450_000)
        #expect(oneTwentyFPS.windowSeconds == 0.10)
        #expect(oneTwentyFPS.bytes == 300_000)
    }

    @Test("Realtime encoder rate control uses data-rate limits on WiFi")
    func realtimeRateControlUsesDataRateLimitsOnWiFi() {
        #expect(VideoEncoder.lowLatencyUsesDataRateLimits(mediaPathProfile: .localWiFi))
        #expect(!VideoEncoder.lowLatencyUsesDataRateLimits(mediaPathProfile: .wired))
        #expect(!VideoEncoder.lowLatencyUsesDataRateLimits(mediaPathProfile: .proximityWiredLike))
        #expect(VideoEncoder.LowLatencyBitrateStrategy.averageBitRateOnly.publicStrategy == .none)
    }

    @Test("AWDL realtime encoder rate control uses constrained VBR")
    func awdlRealtimeRateControlUsesConstrainedVBR() {
        #expect(VideoEncoder.lowLatencyUsesDataRateLimits(mediaPathProfile: .awdlRadio))
        #expect(VideoEncoder.LowLatencyBitrateStrategy.averageBitRateDataRateLimits.publicStrategy == .averageBitRateDataRateLimits)
    }

    @Test("Smoothest encoder specification keeps baseline hardware requirements")
    func smoothestEncoderSpecificationKeepsBaselineHardwareRequirements() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .smoothest,
            streamKind: .window
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency desktop specification enables low-latency rate control")
    func standardLowestLatencyEncoderSpecification() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .lowestLatency,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("Standard balanced desktop specification enables low-latency rate control")
    func standardBalancedDesktopEncoderSpecification() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .balanced,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("AWDL balanced desktop specification suppresses low-latency rate control")
    func awdlBalancedDesktopEncoderSpecificationSuppressesLowLatencyRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .balanced,
            streamKind: .desktop,
            mediaPathProfile: .awdlRadio
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
        #expect(!VideoEncoder.standardLowLatencyVTTuningEnabled(
            latencyMode: .balanced,
            streamKind: .desktop,
            mediaPathProfile: .awdlRadio
        ))
    }

    @Test("AWDL encoder policy favors readability over lowest latency")
    func awdlEncoderPolicyFavorsReadabilityOverLowestLatency() {
        #expect(VideoEncoder.frameDelayCount(for: .balanced, mediaPathProfile: .awdlRadio) == 1)
        #expect(VideoEncoder.frameDelayCount(for: .balanced, mediaPathProfile: .localWiFi) == 0)
        #expect(!VideoEncoder.prioritizeEncodingSpeedOverQuality(mediaPathProfile: .awdlRadio))
        #expect(VideoEncoder.prioritizeEncodingSpeedOverQuality(mediaPathProfile: .localWiFi))
    }

    @Test("Standard lowest-latency desktop specification keeps low-latency rate control at high resolution")
    func standardLowestLatencyHighResDesktopEnablesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .lowestLatency,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }

    @Test("Standard lowest-latency window specification suppresses low-latency rate control at high resolution")
    func standardLowestLatencyHighResWindowSuppressesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .lowestLatency,
            streamKind: .window
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency Ultra window specification enables low-latency rate control")
    func standardLowestLatencyUltraWindowEnablesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            latencyMode: .lowestLatency,
            streamKind: .window,
            colorDepth: .ultra
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool == true)
    }
}
#endif
