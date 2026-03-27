//
//  KeyframeRecoveryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Host keyframe recovery, FEC, and quality cap policy coverage.
//

@testable import MirageKitHost
import MirageKit
import CoreGraphics
import Foundation
import Testing

#if os(macOS)
@Suite("Keyframe Recovery Policy")
struct KeyframeRecoveryPolicyTests {
    @Test("First two recovery requests are soft, third request escalates hard")
    func softSoftHardEscalation() async throws {
        let context = makeContext()

        await context.requestKeyframe()
        #expect(await context.softRecoveryCount == 1)
        #expect(await context.hardRecoveryCount == 0)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframe()
        #expect(await context.softRecoveryCount == 2)
        #expect(await context.hardRecoveryCount == 0)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframe()
        #expect(await context.softRecoveryCount == 2)
        #expect(await context.hardRecoveryCount == 1)
        #expect(await context.pendingKeyframeRequiresReset == true)
        #expect(await context.pendingKeyframeRequiresFlush == true)
    }

    @Test("Capture-starved recovery schedules restart when no frame has arrived")
    func captureStarvedRecoveryWithNoFrames() {
        let shouldRestart = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 0,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(shouldRestart)
    }

    @Test("Capture-starved recovery does not restart while cooldown is active")
    func captureStarvedRecoveryCooldown() {
        let shouldRestart = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 8.0,
            lastRestartTime: 9.5,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(!shouldRestart)
    }

    @Test("Capture-starved recovery waits until frame gap exceeds threshold")
    func captureStarvedRecoveryThreshold() {
        let belowThreshold = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 9.6,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(!belowThreshold)

        let aboveThreshold = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 8.9,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(aboveThreshold)
    }

    @Test("Scheduled keyframes are disabled in recovery-only mode")
    func scheduledKeyframesDisabled() async {
        let context = makeContext()
        let shouldQueue = await context.shouldQueueScheduledKeyframe(queueBytes: 0)
        #expect(shouldQueue == false)
    }

    @Test("Quality mapper enforces frame quality ceiling")
    func bitrateQualityCap() {
        let mapped = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 1_000_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        #expect(mapped.frameQuality <= 0.94)
        #expect(mapped.keyframeQuality <= mapped.frameQuality)
    }

    @Test("High bitrate mapping targets near-lossless quality at 5K60")
    func highBitrateNearLosslessQuality() {
        let mapped = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 700_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        #expect(mapped.frameQuality >= 0.90)
    }

    @Test("600 Mbps mapping stays near-lossless at 5K60")
    func sixHundredMbpsNearLosslessQuality() {
        let mapped = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 600_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        #expect(mapped.frameQuality >= 0.90)
        #expect(mapped.keyframeQuality >= 0.80)
    }

    @Test("25 Mbps mapping compresses aggressively at 5K60")
    func lowBitrateAggressiveCompression() {
        let mapped = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 25_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        #expect(mapped.frameQuality <= 0.15)
        #expect(mapped.keyframeQuality <= 0.09)
    }

    @Test("Stream context applies high-bitrate quality mapping at 5K60")
    func streamContextAppliesHighBitrateQuality() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 700_000_000
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await context.updateCaptureSizesIfNeeded(fiveKSize)
        await context.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let active = await context.activeQuality
        #expect(active >= 0.90)
    }

    @Test("Quality mapper does not apply high-bitrate boost through 400 Mbps")
    func noHighBitrateBoostAtOrBelowThreshold() {
        let standard = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 400_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        let boosted = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 700_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        #expect(standard.frameQuality <= 0.80)
        #expect(boosted.frameQuality > standard.frameQuality)
    }

    @Test("Quality mapper lowers quality for bitrate-constrained streams")
    func bitrateQualityCompressionBias() {
        let constrained = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 20_000_000,
            width: 3840,
            height: 2160,
            frameRate: 60
        )
        let unconstrained = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 400_000_000,
            width: 3840,
            height: 2160,
            frameRate: 60
        )
        #expect(constrained.frameQuality < unconstrained.frameQuality)
        #expect(constrained.frameQuality <= 0.30)
    }

    @Test("Quality mapper biases higher refresh streams toward stronger compression")
    func highRefreshCompressionBias() {
        let sixtyHz = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 25_000_000,
            width: 2560,
            height: 1440,
            frameRate: 60
        )
        let oneTwentyHz = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 50_000_000,
            width: 2560,
            height: 1440,
            frameRate: 120
        )

        #expect(oneTwentyHz.frameQuality < sixtyHz.frameQuality)
    }

    @Test("Low-latency high-res boost does not force compression at 600 Mbps")
    func lowLatencyHighResBoostRespectsHighBitrateHeadroom() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted >= 0.90)
        #expect(abs(boosted - baseline) < 0.02)
    }

    @Test("Low-latency high-res boost remains aggressive at 25 Mbps")
    func lowLatencyHighResBoostStaysAggressiveWhenConstrained() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted <= 0.06)
        #expect(boosted + 0.07 < baseline)
    }

    @Test("High-bitrate 5K120 remains more compressed than 5K60")
    func highBitrateHighRefreshBias() {
        let sixtyHz = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 700_000_000,
            width: 5120,
            height: 2880,
            frameRate: 60
        )
        let oneTwentyHz = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: 700_000_000,
            width: 5120,
            height: 2880,
            frameRate: 120
        )

        #expect(oneTwentyHz.frameQuality < sixtyHz.frameQuality)
    }

    @Test("Bitrate-capped 6K streams allow a lower runtime quality floor")
    func bitrateCappedQualityFloor() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let floor = await context.qualityFloor
        #expect(floor < 0.1)
    }

    @Test("Bitrate-constrained keyframes compress harder when queue pressure rises")
    func keyframePressureQualityDrop() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 300_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality(for: 0)
        let maxQueuedBytes = await context.maxQueuedBytes
        let pressured = await context.keyframeQuality(for: maxQueuedBytes)
        let floor = await context.keyframeQualityFloor

        #expect(pressured < baseline)
        #expect(pressured >= floor)
    }

    @Test("Runtime-quality-disabled streams keep keyframe quality fixed under queue pressure")
    func keyframeQualityStaysFixedWhenRuntimeAdjustmentDisabled() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000,
            runtimeQualityAdjustmentEnabled: false
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality(for: 0)
        let maxQueuedBytes = await context.maxQueuedBytes
        let pressured = await context.keyframeQuality(for: maxQueuedBytes)

        #expect(abs(baseline - pressured) < 0.0001)
    }

    @Test("Recovery requests enable P-frame FEC in loss mode")
    func fecEscalationPolicy() async throws {
        let context = makeContext()

        await context.requestKeyframe()
        let softTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: softTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: softTime) == 16)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframe()
        let hardTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: hardTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: hardTime) == 16)
    }

    @Test("Startup transport protection strengthens keyframe FEC")
    func startupTransportProtectionStrengthensKeyframeFEC() async {
        let context = makeContext()

        await context.enableStartupTransportProtection(now: 10.0)
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: 10.0) == 0)
        #expect(context.startupKeyframePacingOverride(now: 10.0) == StreamPacketSender.PacingOverride(
            rateBps: 120_000_000,
            burstBytes: 64 * 1024
        ))

        await context.disableStartupTransportProtection()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 0)
    }

    @Test("Startup packet pacing caps keyframe burst budget while leaving steady state unchanged")
    func startupPacketPacingCapsKeyframeBurstBudget() {
        let startupParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 600_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: StreamPacketSender.PacingOverride(
                rateBps: 120_000_000,
                burstBytes: 64 * 1024
            )
        )
        let steadyStateParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 600_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: nil
        )

        #expect(startupParameters != nil)
        #expect(steadyStateParameters != nil)
        #expect(Int(startupParameters?.burstBytes ?? 0) == 64 * 1024)
        #expect((startupParameters?.bytesPerSecond ?? 0) < (steadyStateParameters?.bytesPerSecond ?? 0))
        #expect((startupParameters?.burstBytes ?? 0) < (steadyStateParameters?.burstBytes ?? 0))
    }

    private func makeContext(
        frameRate: Int = 60,
        bitrate: Int = 600_000_000,
        runtimeQualityAdjustmentEnabled: Bool = true,
        latencyMode: MirageStreamLatencyMode = .auto,
        lowLatencyHighResolutionCompressionBoostEnabled: Bool = true
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: frameRate,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 1,
            windowID: 1,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoostEnabled,
            latencyMode: latencyMode
        )
    }
}
#endif
