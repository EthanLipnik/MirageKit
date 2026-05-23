//
//  FreshnessBurstTests.swift
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
@Suite("Freshness Burst")
struct FreshnessBurstTests {
    @Test("Severe standard-mode queue pressure enters freshness burst without degrading bitrate or quality")
    func severeQueuePressureEntersFreshnessBurstWithoutQualityDrop() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let baselineBitrate = await context.encoderConfig.bitrate
        let baselineRequestedTargetBitrate = await context.requestedTargetBitrate
        let baselineQualityCeiling = await context.qualityCeiling
        let baselineActiveQuality = await context.activeQuality
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        _ = await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test severe queue"
        )

        #expect(await context.freshnessBurstActive)
        #expect(await context.latencyBurstActive)
        #expect(await context.latencyBurstCaptureQueueDepthOverride == nil)
        #expect(await context.latencyBurstDrainsNewestFrames)
        #expect(await context.freshnessBurstEntryCount == 1)
        #expect(await context.pendingKeyframeReason == nil)
        #expect(context.lossModeDeadline == 0)
        #expect(context.lossModePFrameFECDeadline == 0)
        #expect(await context.encoderConfig.bitrate == baselineBitrate)
        #expect(await context.requestedTargetBitrate == baselineRequestedTargetBitrate)
        #expect(abs(await context.qualityCeiling - baselineQualityCeiling) < 0.0001)
        #expect(abs(await context.activeQuality - baselineActiveQuality) < 0.0001)
    }

    @Test("Explicit recovery keyframes are not swallowed while freshness burst is active")
    func explicitRecoveryKeyframesAreNotSwallowedDuringFreshnessBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        _ = await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test coalesce"
        )

        let softRecoveries = await context.softRecoveryCount

        await context.requestKeyframeRecoveryIfPossible()

        #expect(await context.pendingKeyframeReason == "Keyframe request")
        #expect(await context.pendingKeyframeUrgent)
        #expect(await context.softRecoveryCount == softRecoveries + 1)
        #expect(await context.freshnessBurstEntryCount == 1)
    }

    @Test("Freshness burst exit restores capture queue depth and newest-drain policy")
    func freshnessBurstExitRestoresBaselineQueueBehavior() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000

        _ = await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test restore"
        )
        _ = await context.exitFreshnessBurstIfNeeded(
            queueBytes: 0,
            reason: "queue recovered"
        )

        #expect(!(await context.freshnessBurstActive))
        #expect(!(await context.latencyBurstActive))
        #expect(await context.latencyBurstCaptureQueueDepthOverride == nil)
        #expect(!(await context.latencyBurstDrainsNewestFrames))
        #expect(await context.encoderConfig.captureQueueDepth == 8)
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

        #expect(await context.freshnessBurstActive)
        #expect(await context.freshnessBurstEntryCount == 1)
        #expect(await context.pendingKeyframeReason == nil)
    }

    @Test("Modest non-keyframe sender delay does not enter freshness burst")
    func modestNonKeyframeSenderDelayDoesNotEnterFreshnessBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8
        )
        let telemetry = makeSenderTelemetry(
            sendCompletionMaxMs: 25,
            nonKeyframeSendCompletionMaxMs: 25
        )

        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )
        await context.applySenderFrameBudgetRecoveryIfNeeded(
            packetTelemetry: telemetry,
            frameBudgetMs: 16.7
        )

        #expect(!(await context.freshnessBurstActive))
        #expect(await context.freshnessBurstEntryCount == 0)
        #expect(await context.senderFrameBudgetDelayOverrunCount == 0)
    }

    @Test("Smoothest non-keyframe sender delay uses soft drain instead of recovery burst")
    func smoothestNonKeyframeSenderDelayUsesSoftDrainInsteadOfRecoveryBurst() async {
        let context = makeContext(
            bitrate: 120_000_000,
            captureQueueDepth: 8,
            latencyMode: .smoothest
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

        #expect(!(await context.freshnessBurstActive))
        #expect(!(await context.latencyBurstActive))
        #expect(await context.latencyBurstDrainsNewestFrames)
        #expect(await context.freshnessBurstEntryCount == 0)

        await context.expireSoftFreshnessDrainIfNeeded(at: CFAbsoluteTimeGetCurrent() + 1)
        #expect(!(await context.latencyBurstDrainsNewestFrames))
    }

    @Test("AWDL freshness burst resets sender queue and requests flush keyframe")
    func awdlFreshnessBurstResetsSenderQueueAndRequestsFlushKeyframe() async throws {
        let context = makeContext(
            bitrate: 24_000_000,
            captureQueueDepth: 8,
            transportPathKind: .awdl
        )
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        await context.setupPacketSender(sendPacket: { _, onComplete in
            pendingCompletions.withLock {
                $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete))
            }
        })
        let sender = try #require(await context.packetSender)
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 4096),
                streamID: 88,
                frameNumber: 1,
                sequenceNumberStart: 10,
                generation: generation
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.queuedByteCount > 0)

        let severeQueueBytes = (await context.maxQueuedBytes) + 256_000
        _ = await context.enterFreshnessBurstIfNeeded(
            queueBytes: severeQueueBytes,
            reason: "unit test awdl recovery"
        )

        #expect(await context.pendingKeyframeReason == "AWDL freshness burst")
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(await context.pendingKeyframeUrgent)
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
        #expect(sender.queuedByteCount == 0)

        completePendingStreamPacketSends(pendingCompletions)
        await sender.stop()
    }

    private func makeContext(
        bitrate: Int,
        captureQueueDepth: Int,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        transportPathKind: MirageNetworkPathKind = .unknown
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
            transportPathKind: transportPathKind,
            enteredBitrate: bitrate
        )
    }

    private func makeSenderTelemetry(
        queuedBytes: Int = 0,
        sendStartDelayMaxMs: Double = 0,
        sendCompletionMaxMs: Double = 0,
        nonKeyframeSendStartDelayMaxMs: Double = 0,
        nonKeyframeSendCompletionMaxMs: Double = 0
    ) -> StreamPacketSender.TelemetrySnapshot {
        StreamPacketSender.TelemetrySnapshot(
            queuedBytes: queuedBytes,
            sendStartDelayAverageMs: sendStartDelayMaxMs,
            sendStartDelayMaxMs: sendStartDelayMaxMs,
            sendCompletionAverageMs: sendCompletionMaxMs,
            sendCompletionMaxMs: sendCompletionMaxMs,
            nonKeyframeSendStartDelayMaxMs: nonKeyframeSendStartDelayMaxMs,
            nonKeyframeSendCompletionMaxMs: nonKeyframeSendCompletionMaxMs,
            packetPacerSleepAverageMs: 0,
            packetPacerSleepTotalMs: 0,
            packetPacerSleepMaxMs: 0,
            packetPacerFrameMaxSleepMs: 0,
            stalePacketDrops: 0,
            senderLocalDeadlineDrops: 0,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 0
        )
    }
}
#endif
