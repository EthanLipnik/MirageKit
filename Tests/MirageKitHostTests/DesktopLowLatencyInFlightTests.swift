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

    @Test("120 Hz desktop freshest-frame lowest-latency keeps ProMotion cushion")
    func desktopFreshestFrame120HzLowestLatencyKeepsProMotionCushion() async {
        let context = makeContext(
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 3)
        #expect(await context.maxInFlightFrames == 3)
        #expect(await context.maxInFlightFramesCap == 3)
        #expect(await context.frameBufferDepth == 4)
    }

    @Test("120 Hz desktop freshest-frame lowest-latency minimal buffer stays single-inflight")
    func desktopFreshestFrame120HzLowestLatencyMinimalBufferStaysSingleInflight() async {
        let context = makeContext(
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame,
            hostBufferDepth: .minimal
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 1)
        #expect(await context.maxInFlightFrames == 1)
        #expect(await context.maxInFlightFramesCap == 1)
        #expect(await context.frameBufferDepth == 1)
    }

    @Test("120 Hz desktop freshest-frame lowest-latency high buffer increases ProMotion cushion")
    func desktopFreshestFrame120HzLowestLatencyHighBufferIncreasesProMotionCushion() async {
        let context = makeContext(
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame,
            hostBufferDepth: .high
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 4)
        #expect(await context.maxInFlightFrames == 4)
        #expect(await context.maxInFlightFramesCap == 4)
        #expect(await context.frameBufferDepth == 5)
    }

    @Test("120 Hz desktop freshest-frame lowest-latency maximum buffer keeps bounded ProMotion depth")
    func desktopFreshestFrame120HzLowestLatencyMaximumBufferKeepsBoundedProMotionDepth() async {
        let context = makeContext(
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame,
            hostBufferDepth: .maximum
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 5)
        #expect(await context.maxInFlightFrames == 5)
        #expect(await context.maxInFlightFramesCap == 5)
        #expect(await context.frameBufferDepth == 6)
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

    @Test("120 Hz desktop freshest-frame balanced high buffer increases cushion")
    func desktopFreshestFrame120HzBalancedHighBufferIncreasesCushion() async {
        let context = makeContext(
            latencyMode: .balanced,
            targetFrameRate: 120,
            hostBufferingPolicy: .freshestFrame,
            hostBufferDepth: .high
        )

        await context.updateInFlightLimitIfNeeded(averageEncodeMs: 40, pendingCount: 4)

        #expect(await context.minInFlightFrames == 3)
        #expect(await context.maxInFlightFrames == 4)
        #expect(await context.maxInFlightFramesCap == 4)
        #expect(await context.frameBufferDepth == 4)
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

    @Test("120 Hz desktop smoothest maximum buffer increases smoothing capacity")
    func desktopSmoothest120HzMaximumBufferIncreasesSmoothingCapacity() async {
        let context = makeContext(
            latencyMode: .smoothest,
            targetFrameRate: 120,
            hostBufferDepth: .maximum
        )

        #expect(await context.minInFlightFrames == 4)
        #expect(await context.maxInFlightFrames == 4)
        #expect(await context.maxInFlightFramesCap == 10)
        #expect(await context.frameBufferDepth == 14)
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

    @Test("AWDL fixed-cadence desktop keeps stability host pipeline")
    func awdlFixedCadenceDesktopKeepsStabilityHostPipeline() async {
        let context = makeContext(
            latencyMode: .balanced,
            targetFrameRate: 30,
            hostBufferingPolicy: .stability,
            mediaPathProfile: .awdlRadio
        )

        #expect(context.currentFrameRate == MirageAwdlMediaController.awdlRadioFrameRate)
        #expect(await context.minInFlightFrames == 2)
        #expect(await context.maxInFlightFrames == 2)
        #expect(await context.maxInFlightFramesCap == 3)
        #expect(await context.frameBufferDepth == 3)
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
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        targetFrameRate: Int = 60,
        hostBufferingPolicy: MirageHostBufferingPolicy = .stability,
        hostBufferDepth: MirageHostBufferDepth = .standard,
        mediaPathProfile: MirageMediaPathProfile? = nil
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
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            hostBufferDepth: hostBufferDepth,
            mediaPathProfile: mediaPathProfile
        )
    }
}
#endif
