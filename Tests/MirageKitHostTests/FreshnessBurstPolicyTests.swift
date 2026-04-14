//
//  FreshnessBurstPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Coverage for freshness-first severe-overload recovery in standard mode.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Freshness Burst Policy")
struct FreshnessBurstPolicyTests {
    @Test("Severe standard-mode queue pressure enters freshness burst without degrading bitrate or quality")
    func severeQueuePressureEntersFreshnessBurstWithoutQualityDrop() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let baselineSettings = await context.getEncoderSettings()
        let baselineBurst = await context.freshnessBurstSnapshot()
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test severe queue"
        )

        let burst = await context.freshnessBurstSnapshot()
        let settings = await context.getEncoderSettings()

        #expect(burst.isActive)
        #expect(burst.latencyBurstActive)
        #expect(burst.captureQueueDepthOverride == 2)
        #expect(burst.newestFrameDrainEnabled)
        #expect(burst.entryCount == 1)
        #expect(burst.queueResetCount == 1)
        #expect(burst.recoveryKeyframeCount == 1)
        #expect(settings.bitrate == baselineSettings.bitrate)
        #expect(settings.requestedTargetBitrate == baselineSettings.requestedTargetBitrate)
        #expect(abs(burst.qualityCeiling - baselineBurst.qualityCeiling) < 0.0001)
        #expect(abs(burst.activeQuality - baselineBurst.activeQuality) < 0.0001)
    }

    @Test("Recovery keyframe requests coalesce while freshness burst is active")
    func recoveryKeyframesCoalesceDuringFreshnessBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test coalesce"
        )

        let pendingKeyframeReason = await context.pendingKeyframeReason
        let softRecoveries = await context.softRecoveryCount
        let hardRecoveries = await context.hardRecoveryCount

        await context.requestKeyframe()

        let burst = await context.freshnessBurstSnapshot()
        #expect(await context.pendingKeyframeReason == pendingKeyframeReason)
        #expect(await context.pendingKeyframeUrgent)
        #expect(await context.softRecoveryCount == softRecoveries)
        #expect(await context.hardRecoveryCount == hardRecoveries)
        #expect(burst.entryCount == 1)
        #expect(burst.queueResetCount == 1)
        #expect(burst.recoveryKeyframeCount == 1)
        #expect(burst.coalescedRecoveryKeyframeCount == 1)
    }

    @Test("Freshness burst exit restores capture queue depth and newest-drain policy")
    func freshnessBurstExitRestoresBaselineQueueBehavior() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test restore"
        )
        _ = await context.exitFreshnessBurstIfNeeded(
            queueBytes: 0,
            reason: "queue recovered"
        )

        let burst = await context.freshnessBurstSnapshot()
        let settings = await context.getEncoderSettings()

        #expect(!burst.isActive)
        #expect(!burst.latencyBurstActive)
        #expect(burst.captureQueueDepthOverride == nil)
        #expect(!burst.newestFrameDrainEnabled)
        #expect(settings.captureQueueDepth == 8)
    }

    private func makeContext(
        bitrate: Int,
        captureQueueDepth: Int
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorDepth: .standard,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 88,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: config,
            runtimeQualityAdjustmentEnabled: true,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            performanceMode: .standard,
            enteredBitrate: bitrate
        )
    }
}
#endif
