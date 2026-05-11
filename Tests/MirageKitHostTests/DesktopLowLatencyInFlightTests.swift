//
//  DesktopLowLatencyInFlightTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

@Suite("Desktop Low Latency In Flight")
struct DesktopLowLatencyInFlightTests {

    @Test("60 Hz desktop lowest-latency stays single-inflight")
    func desktopLowestLatencyStaysSingleInflight() async {
        let context = makeContext()

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)

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

    @Test("120 Hz lowest-latency never raises in-flight")
    func highRefreshLowestLatencyNeverRaisesInflight() async {
        let context = makeContext(targetFrameRate: 120)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 14, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
    }

    @Test("60 Hz desktop smoothest is bounded by target latency")
    func desktopSmoothestIsBoundedByTargetLatency() async {
        let context = makeContext(latencyMode: .smoothest)

        #expect(await context.minInFlightFrames == 1)
        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 10, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 2)
    }

    @Test("Lowest-latency non-keyframe send deadline is shorter than Smoothest")
    func lowestLatencyNonKeyframeSendDeadlineIsShorterThanSmoothest() {
        let encodedAt = CFAbsoluteTimeGetCurrent()
        let lowestLatencyDeadline = StreamContext.packetSendDeadline(
            encodedAt: encodedAt,
            isKeyframe: false,
            targetFrameRate: 60,
            latencyMode: .lowestLatency
        )
        let smoothestDeadline = StreamContext.packetSendDeadline(
            encodedAt: encodedAt,
            isKeyframe: false,
            targetFrameRate: 60,
            latencyMode: .smoothest
        )

        #expect(lowestLatencyDeadline < smoothestDeadline)
        #expect(lowestLatencyDeadline - encodedAt < 0.050)
        #expect(smoothestDeadline - encodedAt >= 0.100)
    }

    private func makeContext(
        streamKind: VideoEncoder.StreamKind = .desktop,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        targetFrameRate: Int = 60
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: targetFrameRate,
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
            latencyMode: latencyMode
        )
    }
}
#endif
