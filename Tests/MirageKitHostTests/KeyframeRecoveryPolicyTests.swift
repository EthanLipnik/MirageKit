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

    @Test("Soft recovery keeps P-frame FEC off and hard recovery enables it")
    func fecEscalationPolicy() async throws {
        let context = makeContext()

        await context.requestKeyframe()
        let softTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: softTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: softTime) == 0)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframe()
        let hardTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: hardTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: hardTime) == 16)
    }

    private func makeContext() -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 600_000_000
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
