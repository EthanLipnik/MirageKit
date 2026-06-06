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
import MirageMedia

@Suite("Desktop Low Latency In Flight")
struct DesktopLowLatencyInFlightTests {
    @Test("60 Hz desktop lowest-latency stability keeps bounded two-frame inflight")
    func desktopLowestLatencyStabilityKeepsBoundedTwoFrameInflight() async {
        let context = makeContext()

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 10, pendingCount: 0)

        #expect(await context.maxInFlightFrames == 2)
    }

    @Test("60 Hz desktop freshest-frame lowest-latency stays single-inflight")
    func desktopFreshestFrameLowestLatencyStaysSingleInflight() async {
        let context = makeContext(hostBufferingPolicy: .freshestFrame)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("60 Hz window lowest-latency stays single-inflight")
    func windowLowestLatencyStaysSingleInflight() async {
        let context = makeContext(streamKind: .window)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("60 Hz app atlas freshest-frame lowest-latency stays single-inflight")
    func appAtlasFreshestFrameLowestLatencyStaysSingleInflight() async {
        let context = makeContext(
            streamKind: .appAtlas,
            hostBufferingPolicy: .freshestFrame
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("120 Hz desktop freshest-frame lowest-latency stays single-inflight")
    func desktopFreshestFrame120HzLowestLatencyStaysSingleInflight() async {
        let context = makeContext(
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("60 Hz desktop freshest-frame balanced keeps two-frame cushion")
    func desktopFreshestFrameBalancedKeepsTwoFrameCushion() async {
        let context = makeContext(
            latencyMode: .balanced,
            hostBufferingPolicy: .freshestFrame
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.minInFlightFrames == 1)
        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)
    }

    @Test("120 Hz desktop freshest-frame balanced keeps three-frame cushion")
    func desktopFreshestFrame120HzBalancedKeepsThreeFrameCushion() async {
        let context = makeContext(
            latencyMode: .balanced,
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 2)
        #expect(await context.maxInFlightFrames == 3)
        #expect(await context.maxInFlightFramesCap == 3)
        #expect(await context.frameBufferDepth == 3)
    }

    @Test("60 Hz desktop smoothest keeps smoothing capacity")
    func desktopSmoothestKeepsSmoothingCapacity() async {
        let context = makeContext(latencyMode: .smoothest)

        #expect(await context.minInFlightFrames == 2)
        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 3)
        #expect(await context.frameBufferDepth == 3)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 3)
    }

    @Test("AWDL desktop starts with sidecar-style host pipeline slack")
    func awdlDesktopStartsWithSidecarStyleHostPipelineSlack() async {
        let context = makeContext(
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            mediaPathProfile: .awdlRadio
        )

        #expect(await context.latencyMode == .balanced)
        #expect(await context.hostBufferingPolicy == .stability)
        #expect(await context.useLowLatencyPipeline == false)
        #expect(await context.minInFlightFrames == 2)
        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 3)
        #expect(await context.frameBufferDepth == 3)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 28, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 3)
    }

    @Test("AWDL 30 fps demoted desktop keeps bounded host pipeline")
    func awdl30FPSDemotedDesktopKeepsBoundedHostPipeline() async {
        let context = makeContext(
            latencyMode: .balanced,
            targetFrameRate: 30,
            hostBufferingPolicy: .stability,
            mediaPathProfile: .awdlRadio
        )

        #expect(await context.minInFlightFrames == 1)
        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 2)
        #expect(await context.frameBufferDepth == 2)
    }

    @Test("120 Hz desktop smoothest keeps enough host pipeline depth")
    func desktopSmoothest120HzKeepsEnoughHostPipelineDepth() async {
        let context = makeContext(
            latencyMode: .smoothest,
            targetFrameRate: 120
        )

        #expect(await context.minInFlightFrames == 2)
        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 8)
        #expect(await context.frameBufferDepth == 12)

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.maxInFlightFrames == 3)
    }

    private func makeContext(
        streamKind: VideoEncoder.StreamKind = .desktop,
        latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency,
        targetFrameRate: Int = 60,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .stability,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
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
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            mediaPathProfile: mediaPathProfile
        )
    }
}
#endif
