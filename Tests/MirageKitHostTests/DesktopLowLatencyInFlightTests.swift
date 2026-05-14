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

@Suite("Desktop Low Latency In Flight")
struct DesktopLowLatencyInFlightTests {
    @Test("60 Hz desktop lowest-latency keeps bounded two-frame inflight")
    func desktopLowestLatencyKeepsBoundedTwoFrameInflight() async {
        let context = makeContext()

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 10, pendingCount: 0)

        #expect(await context.maxInFlightFrames == 2)
    }

    @Test("60 Hz window lowest-latency stays single-inflight")
    func windowLowestLatencyStaysSingleInflight() async {
        let context = makeContext(streamKind: .window)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("60 Hz desktop smoothest keeps smoothing capacity")
    func desktopSmoothestKeepsSmoothingCapacity() async {
        let context = makeContext(latencyMode: .smoothest)

        #expect(await context.minInFlightFrames == 3)
        #expect(await context.maxInFlightFrames == 3)
        #expect(await context.maxInFlightFramesCap == 4)
        #expect(await context.frameBufferDepth == 5)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 4)
    }

    @Test("120 Hz desktop smoothest keeps enough host pipeline depth")
    func desktopSmoothest120HzKeepsEnoughHostPipelineDepth() async {
        let context = makeContext(
            latencyMode: .smoothest,
            targetFrameRate: 120
        )

        #expect(await context.minInFlightFrames == 6)
        #expect(await context.maxInFlightFrames == 6)
        #expect(await context.maxInFlightFramesCap == 8)
        #expect(await context.frameBufferDepth == 12)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 7)
    }

    private func makeContext(
        streamKind: VideoEncoder.StreamKind = .desktop,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        targetFrameRate: Int = 60
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: targetFrameRate,
            keyFrameInterval: 1800,
            colorDepth: .pro,
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
            latencyMode: latencyMode
        )
    }
}
#endif
