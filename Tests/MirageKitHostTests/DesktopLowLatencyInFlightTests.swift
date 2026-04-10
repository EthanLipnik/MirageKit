//
//  DesktopLowLatencyInFlightTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Desktop Low Latency In-Flight Policy")
struct DesktopLowLatencyInFlightTests {
    @Test("60 Hz desktop lowest-latency starts adaptive single-inflight with two-slot cap")
    func desktopLowestLatencyStartsSingleInflight() async {
        let context = makeContext()

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)
    }

    @Test("60 Hz desktop lowest-latency raises inflight under pressure and restores after recovery")
    func desktopLowestLatencyAdjustmentRaisesAndRestoresInflight() async {
        let context = makeContext()

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 2)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 10, pendingCount: 0)

        #expect(await context.maxInFlightFrames == 1)
    }

    @Test("60 Hz window lowest-latency stays single-inflight")
    func windowLowestLatencyStaysSingleInflight() async {
        let context = makeContext(streamKind: .window)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("60 Hz desktop game mode keeps fixed two-inflight policy")
    func desktopGameModeKeepsFixedTwoInflight() async {
        let context = makeContext(performanceMode: .game)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 10, pendingCount: 0)

        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)
    }

    private func makeContext(
        streamKind: VideoEncoder.StreamKind = .desktop,
        performanceMode: MirageStreamPerformanceMode = .standard
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 600_000_000
        )
        return StreamContext(
            streamID: 1,
            windowID: 0,
            streamKind: streamKind,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            runtimeQualityAdjustmentEnabled: false,
            lowLatencyHighResolutionCompressionBoostEnabled: false,
            latencyMode: .lowestLatency,
            performanceMode: performanceMode
        )
    }
}
#endif
