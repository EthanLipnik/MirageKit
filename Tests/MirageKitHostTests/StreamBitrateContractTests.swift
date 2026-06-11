//
//  StreamBitrateContractTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKitHost
import CoreFoundation
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

    @Test("Uncapped stream context bypasses default encoded dimension cap")
    func uncappedStreamContextBypassesDefaultEncodedDimensionCap() async {
        let context = makeContext(
            bitrate: 300_000_000,
            disableResolutionCap: true
        )

        let scale = await context.resolvedStreamScale(
            for: CGSize(width: 6000, height: 3376),
            requestedScale: 1.0,
            logLabel: nil
        )
        let encodedSize = await context.scaledOutputSize(for: CGSize(width: 6000, height: 3376))

        #expect(scale == 1.0)
        #expect(encodedSize == CGSize(width: 6000, height: 3376))
    }

    @Test("Uncapped stream context ignores encoder max dimensions")
    func uncappedStreamContextIgnoresEncoderMaxDimensions() async {
        let context = makeContext(
            bitrate: 300_000_000,
            disableResolutionCap: true,
            encoderMaxWidth: 3840,
            encoderMaxHeight: 2160
        )

        let scale = await context.resolvedStreamScale(
            for: CGSize(width: 6000, height: 3376),
            requestedScale: 1.0,
            logLabel: nil
        )
        let encodedSize = await context.scaledOutputSize(for: CGSize(width: 6000, height: 3376))

        #expect(scale == 1.0)
        #expect(encodedSize == CGSize(width: 6000, height: 3376))
    }

    @Test("Default stream context still applies encoded dimension cap")
    func defaultStreamContextStillAppliesEncodedDimensionCap() async {
        let context = makeContext(bitrate: 300_000_000)

        let scale = await context.resolvedStreamScale(
            for: CGSize(width: 6000, height: 3376),
            requestedScale: 1.0,
            logLabel: nil
        )
        let encodedSize = await context.scaledOutputSize(for: CGSize(width: 6000, height: 3376))

        #expect(scale < 1.0)
        #expect(encodedSize.width <= StreamContext.maxEncodedWidth)
        #expect(encodedSize.height <= StreamContext.maxEncodedHeight)
    }

    @Test("Healthy runtime budget refresh raises active quality")
    func healthyRuntimeBudgetRefreshRaisesActiveQuality() async {
        let context = makeContext(bitrate: 180_000_000)
        await context.configureRuntimeQualityRefreshTest(
            size: CGSize(width: 5104, height: 2864),
            activeQuality: 0.04
        )

        await context.refreshRuntimeQualityTargets(
            for: 300_000_000,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )

        #expect(await context.activeQualityForTest() > 0.04)
        #expect(await context.steadyQualityCeilingForTest() > 0.04)
    }

    @Test("Healthy runtime budget refresh clears stale realtime quality ceiling")
    func healthyRuntimeBudgetRefreshClearsStaleRealtimeQualityCeiling() async {
        let context = makeContext(bitrate: 76_700_000)
        await context.configureRuntimeQualityRefreshTest(
            size: CGSize(width: 2752, height: 2064),
            activeQuality: 0.20
        )
        await context.setRealtimeRuntimeQualityCeilingForTest(0.25)

        await context.refreshRuntimeQualityTargets(
            for: 120_000_000,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )

        #expect(await context.realtimeRuntimeQualityCeilingForTest() == nil)
        #expect(await context.activeQualityForTest() > 0.25)
    }

    @Test("Healthy frame budget decision applies gradual quality raise")
    func healthyFrameBudgetDecisionAppliesGradualQualityRaise() async {
        let context = makeContext(bitrate: 60_000_000)
        await context.configureRunningForBitrateContractTest()
        await context.configureRuntimeQualityRefreshTest(
            size: CGSize(width: 2752, height: 2064),
            activeQuality: 0.42
        )
        let gradualQuality: Float = 0.44

        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 221_500_000,
                maxFrameBytes: 461_459,
                maxWireBytes: 461_459,
                maxPacketCount: 385,
                quality: gradualQuality,
                qualityCeiling: 0.90,
                keyframeQuality: 0.70,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 1,
                state: .observing,
                reason: .healthy
            ),
            now: CFAbsoluteTimeGetCurrent()
        )
        let activeQuality = await context.activeQualityForTest()

        #expect(abs(activeQuality - gradualQuality) < 0.0001)
        #expect(await context.qualityCeilingForTest() > gradualQuality)
    }

    @Test("Healthy frame budget decision does not lower newer local bitrate raise")
    func healthyFrameBudgetDecisionDoesNotLowerNewerLocalBitrateRaise() async {
        let context = makeContext(
            bitrate: 116_000_000,
            bitrateAdaptationCeiling: 180_000_000
        )
        await context.configureRunningForBitrateContractTest()
        await context.configureRuntimeQualityRefreshTest(
            size: CGSize(width: 2752, height: 2064),
            activeQuality: 0.58
        )
        await context.applyRealtimeBudgetBitrate(
            134_562_413,
            ceilingBitrateBps: 180_000_000,
            encoderRateHintBps: 134_562_413,
            senderPacingBitrateBps: 134_562_413,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )
        let raisedTarget = await context.currentTargetBitrateForTest()
        let raisedQuality = await context.activeQualityForTest()

        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 116_200_000,
                maxFrameBytes: 242_083,
                maxWireBytes: 242_083,
                maxPacketCount: 202,
                quality: 0.42,
                qualityCeiling: 0.90,
                keyframeQuality: 0.70,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 1,
                state: .observing,
                reason: .healthy
            ),
            now: CFAbsoluteTimeGetCurrent()
        )
        let runtimeCeiling = (await context.realtimeRuntimeBitrateCeilingForTest()) ?? 0

        #expect(await context.currentTargetBitrateForTest() == raisedTarget)
        #expect(await context.realtimeEncoderRateHintForTest() == raisedTarget)
        #expect(await context.realtimeSenderPacingBitrateForTest() == raisedTarget)
        #expect(runtimeCeiling >= raisedTarget)
        #expect(await context.activeQualityForTest() >= raisedQuality)
    }

    @Test("Bitrate update clears stale runtime pressure ceilings before deriving quality")
    func bitrateUpdateClearsStaleRuntimePressureCeilingsBeforeDerivingQuality() async throws {
        let context = makeContext(bitrate: 76_700_000)
        await context.configureRunningForBitrateContractTest()
        await context.configureRuntimeQualityRefreshTest(
            size: CGSize(width: 2752, height: 2064),
            activeQuality: 0.42
        )
        await context.setRealtimeRuntimeQualityCeilingForTest(0.42)
        await context.setRealtimeRuntimeBitrateCeilingForTest(76_700_000)

        try await context.updateEncoderSettings(
            colorDepth: nil,
            bitrate: 221_500_000,
            bitrateAdaptationCeiling: 221_500_000,
            updateRequestedTargetBitrate: true
        )

        #expect(await context.realtimeRuntimeQualityCeilingForTest() == nil)
        #expect(await context.realtimeRuntimeBitrateCeilingForTest() == nil)
        #expect(await context.qualityCeilingForTest() > 0.42)
        #expect(await context.activeQualityForTest() > 0.42)
    }

    private func makeContext(
        bitrate: Int,
        bitrateAdaptationCeiling: Int? = nil,
        disableResolutionCap: Bool = false,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil
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
            disableResolutionCap: disableResolutionCap,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
    }
}

private extension StreamContext {
    func configureRunningForBitrateContractTest() {
        isRunning = true
    }

    func configureRuntimeQualityRefreshTest(size: CGSize, activeQuality: Float) {
        currentEncodedSize = size
        self.activeQuality = activeQuality
    }

    func activeQualityForTest() -> Float {
        activeQuality
    }

    func steadyQualityCeilingForTest() -> Float {
        steadyQualityCeiling
    }

    func qualityCeilingForTest() -> Float {
        qualityCeiling
    }

    func currentTargetBitrateForTest() -> Int {
        currentTargetBitrateBps ?? 0
    }

    func realtimeEncoderRateHintForTest() -> Int {
        realtimeEncoderRateHintBps ?? 0
    }

    func realtimeSenderPacingBitrateForTest() -> Int {
        realtimeSenderPacingBitrateBps ?? 0
    }

    func setRealtimeRuntimeQualityCeilingForTest(_ ceiling: Float) {
        realtimeRuntimeQualityCeiling = ceiling
    }

    func setRealtimeRuntimeBitrateCeilingForTest(_ ceiling: Int) {
        realtimeRuntimeBitrateCeilingBps = ceiling
    }

    func realtimeRuntimeQualityCeilingForTest() -> Float? {
        realtimeRuntimeQualityCeiling
    }

    func realtimeRuntimeBitrateCeilingForTest() -> Int? {
        realtimeRuntimeBitrateCeilingBps
    }
}
#endif
