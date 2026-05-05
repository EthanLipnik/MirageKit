//
//  FreshnessBurstPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Coverage for freshness-first severe-overload recovery in standard mode.
//

@testable import MirageKitHost
import Foundation
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

    @Test("Keyframe-only sender delay does not enter freshness burst")
    func keyframeOnlySenderDelayDoesNotEnterFreshnessBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let telemetry = makeSenderTelemetry(
            sendCompletionMaxMs: 55,
            keyframeSendMaxMs: 55
        )

        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )
        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )

        let burst = await context.freshnessBurstSnapshot()
        #expect(!burst.isActive)
        #expect(burst.entryCount == 0)
        #expect(await context.senderFrameBudgetDelayOverrunCount == 0)
    }

    @Test("Lowest-latency non-keyframe sender delay still enters freshness burst")
    func lowestLatencyNonKeyframeSenderDelayStillEntersFreshnessBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let telemetry = makeSenderTelemetry(
            sendCompletionMaxMs: 55,
            nonKeyframeSendCompletionMaxMs: 55
        )

        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )
        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )

        let burst = await context.freshnessBurstSnapshot()
        #expect(burst.isActive)
        #expect(burst.entryCount == 1)
        #expect(burst.recoveryKeyframeCount == 1)
    }

    @Test("Automatic non-keyframe sender delay uses soft drain instead of recovery burst")
    func automaticNonKeyframeSenderDelayUsesSoftDrainInsteadOfRecoveryBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8,
            latencyMode: .auto
        )
        let telemetry = makeSenderTelemetry(
            sendCompletionMaxMs: 55,
            nonKeyframeSendCompletionMaxMs: 55
        )

        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )
        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )

        let burst = await context.freshnessBurstSnapshot()
        #expect(!burst.isActive)
        #expect(!burst.latencyBurstActive)
        #expect(burst.newestFrameDrainEnabled)
        #expect(burst.entryCount == 0)
        #expect(burst.recoveryKeyframeCount == 0)

        await context.expireSoftFreshnessDrainIfNeeded(at: CFAbsoluteTimeGetCurrent() + 1)
        let expired = await context.freshnessBurstSnapshot()
        #expect(!expired.newestFrameDrainEnabled)
    }

    private func makeContext(
        bitrate: Int,
        captureQueueDepth: Int,
        latencyMode: MirageStreamLatencyMode = .lowestLatency
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
            latencyMode: latencyMode,
            performanceMode: .standard,
            enteredBitrate: bitrate
        )
    }

    private func makeSenderTelemetry(
        queuedBytes: Int = 0,
        sendStartDelayMaxMs: Double = 0,
        sendCompletionMaxMs: Double = 0,
        nonKeyframeSendStartDelayMaxMs: Double = 0,
        nonKeyframeSendCompletionMaxMs: Double = 0,
        keyframeSendMaxMs: Double = 0
    ) -> StreamPacketSender.TelemetrySnapshot {
        StreamPacketSender.TelemetrySnapshot(
            queuedBytes: queuedBytes,
            sendStartDelayAverageMs: sendStartDelayMaxMs,
            sendStartDelayMaxMs: sendStartDelayMaxMs,
            sendCompletionAverageMs: sendCompletionMaxMs,
            sendCompletionMaxMs: sendCompletionMaxMs,
            nonKeyframeSendStartDelayAverageMs: nonKeyframeSendStartDelayMaxMs,
            nonKeyframeSendStartDelayMaxMs: nonKeyframeSendStartDelayMaxMs,
            nonKeyframeSendCompletionAverageMs: nonKeyframeSendCompletionMaxMs,
            nonKeyframeSendCompletionMaxMs: nonKeyframeSendCompletionMaxMs,
            keyframeSendAverageMs: keyframeSendMaxMs,
            keyframeSendMaxMs: keyframeSendMaxMs,
            packetPacerSleepAverageMs: 0,
            packetPacerSleepTotalMs: 0,
            packetPacerSleepMaxMs: 0,
            packetPacerFrameMaxSleepMs: 0,
            packetPacerSleepCount: 0,
            stalePacketDrops: 0,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 0
        )
    }
}
#endif
