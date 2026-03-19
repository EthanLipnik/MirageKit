//
//  VideoEncoderRateLimitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/19/26.
//
//  Coverage for encoder data-rate limit budget calculations.
//

@testable import MirageKitHost
import MirageKit
import Testing
import VideoToolbox

#if os(macOS)
@Suite("HEVC Encoder Rate Limits")
struct VideoEncoderRateLimitTests {
    @Test("120 Hz data-rate limit uses window budget bytes")
    func highRefreshBudget() {
        let limit = VideoEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 120
        )

        #expect(limit.windowSeconds == 0.25)
        #expect(limit.bytes == 2_500_000)
    }

    @Test("60 Hz data-rate limit uses window budget bytes")
    func standardRefreshBudget() {
        let limit = VideoEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 60
        )

        #expect(limit.windowSeconds == 0.5)
        #expect(limit.bytes == 5_000_000)
    }

    @Test("Game mode uses single-frame data-rate window at 120 Hz")
    func gameModeHighRefreshBudget() {
        let limit = VideoEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 120,
            performanceMode: .game
        )

        #expect(limit.windowSeconds == 1.0 / 120.0)
        #expect(limit.bytes == 83_333)
    }

    @Test("Game mode uses single-frame data-rate window at 60 Hz")
    func gameModeStandardRefreshBudget() {
        let limit = VideoEncoder.dataRateLimit(
            targetBitrateBps: 80_000_000,
            targetFrameRate: 60,
            performanceMode: .game
        )

        #expect(limit.windowSeconds == 1.0 / 60.0)
        #expect(limit.bytes == 166_667)
    }

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

    @Test("Standard lowest-latency desktop specification suppresses low-latency rate control for low-res desktop")
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
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency desktop specification suppresses low-latency rate control at high resolution")
    func standardLowestLatencyHighResDesktopSuppressesRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 6_016,
            height: 3_384,
            streamKind: .desktop
        )

        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] == nil)
    }

    @Test("Standard lowest-latency window specification keeps low-latency rate control at high resolution")
    func standardLowestLatencyHighResWindowKeepsRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .standard,
            latencyMode: .lowestLatency,
            width: 6_016,
            height: 3_384,
            streamKind: .window
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

    @Test("QP clamp policy applies in baseline game mode")
    func gameModeBaselineQPClampPolicy() {
        let shouldApply = VideoEncoder.shouldApplyQPClamps(
            for: .game,
            gameModeEmergencyQualityClampsEnabled: false
        )
        #expect(shouldApply)
    }

    @Test("QP clamp policy applies in emergency game mode")
    func gameModeEmergencyQPClampPolicy() {
        let shouldApply = VideoEncoder.shouldApplyQPClamps(
            for: .game,
            gameModeEmergencyQualityClampsEnabled: true
        )
        #expect(shouldApply)
    }

    @Test("QP clamp policy always applies in standard mode")
    func standardModeQPClampPolicy() {
        let shouldApply = VideoEncoder.shouldApplyQPClamps(
            for: .standard,
            gameModeEmergencyQualityClampsEnabled: false
        )
        #expect(shouldApply)
    }
}
#endif
