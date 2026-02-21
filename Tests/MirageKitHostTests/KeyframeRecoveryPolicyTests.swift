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
    @Test("First recovery request is soft, second request escalates hard")
    func softThenHardEscalation() async throws {
        let context = makeContext()

        await context.requestKeyframe()
        #expect(await context.softRecoveryCount == 1)
        #expect(await context.hardRecoveryCount == 0)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframe()
        #expect(await context.softRecoveryCount == 1)
        #expect(await context.hardRecoveryCount == 1)
        #expect(await context.pendingKeyframeRequiresReset == true)
        #expect(await context.pendingKeyframeRequiresFlush == true)
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
        #expect(mapped.frameQuality <= 0.80)
        #expect(mapped.keyframeQuality <= mapped.frameQuality)
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
            bitrate: 120_000_000
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

    private func makeContext(
        frameRate: Int = 60,
        bitrate: Int = 600_000_000
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
            streamScale: 1.0
        )
    }
}
#endif
