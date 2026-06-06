//
//  RecoveryReasonAndBackoffTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Coverage for capture restart backoff and recovery-reason keyframe behavior.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Foundation
import Testing
import MirageCore
import MirageMedia

@Suite("Recovery Reason Mapping")
struct RecoveryReasonMappingTests {
    @Test("Capture restart keyframe resets only when escalation is requested")
    func captureRestartResetRequiresEscalation() async {
        let nonEscalated = makeContext()
        await nonEscalated.forceKeyframeAfterCaptureRestart(
            restartStreak: 1,
            shouldEscalateRecovery: false
        )
        #expect(await nonEscalated.pendingKeyframeRequiresFlush)
        #expect(await nonEscalated.pendingKeyframeRequiresReset == false)
        #expect(nonEscalated.epoch == 0)
        #expect(nonEscalated.lossModeDeadline == 0)
        #expect(nonEscalated.lossModePFrameFECDeadline == 0)

        let escalated = makeContext()
        await escalated.forceKeyframeAfterCaptureRestart(
            restartStreak: 3,
            shouldEscalateRecovery: true
        )
        #expect(await escalated.pendingKeyframeRequiresFlush)
        #expect(await escalated.pendingKeyframeRequiresReset)
        #expect(escalated.epoch == 1)
        #expect(escalated.lossModeDeadline == 0)
        #expect(escalated.lossModePFrameFECDeadline == 0)
    }

    @Test("Transport loss still enables loss mode")
    func transportLossStillEnablesLossMode() async {
        let context = makeContext()

        await context.noteLossEvent(reason: "transport test", enablePFrameFEC: true)

        #expect(context.lossModeDeadline > CFAbsoluteTimeGetCurrent())
        #expect(context.lossModePFrameFECDeadline > CFAbsoluteTimeGetCurrent())
    }

    @Test("Coalesced resize recovery keeps the first armed keyframe")
    func coalescedResizeRecoveryKeepsFirstArmedKeyframe() async {
        let context = makeContext()

        await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize reset",
            noteLoss: true,
            requiresFlush: true,
            requiresReset: true,
            ignoreExistingInFlight: true
        )
        let armedDeadline = await context.keyframeSendDeadline

        await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize resume",
            resetFrameNumber: true
        )

        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.keyframeSendDeadline == armedDeadline)
    }

    @Test("Client recovery request does not override an armed resize keyframe")
    func clientRecoveryRequestDoesNotOverrideArmedResizeKeyframe() async {
        let context = makeContext()

        await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize reset",
            noteLoss: true,
            requiresFlush: true,
            requiresReset: true,
            ignoreExistingInFlight: true
        )
        await context.requestKeyframeRecoveryIfPossible()

        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.softRecoveryCount == 0)
    }

    @Test("Generic reconfiguration can preserve an armed desktop resize keyframe")
    func genericReconfigurationCanPreserveArmedDesktopResizeKeyframe() async {
        let context = makeContext(transportPathKind: .awdl)

        await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize reset",
            noteLoss: true,
            requiresFlush: true,
            requiresReset: true,
            ignoreExistingInFlight: true
        )

        await context.resetPipelineStateForReconfiguration(
            reason: "unit-test-retune",
            preservePendingGeometryRecoveryKeyframe: true
        )

        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeUrgent)
        #expect(await context.keyframeSendDeadline == 0)
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Repeated client background pause clears sender queue while already paused")
    func repeatedClientBackgroundPauseClearsSenderQueueWhileAlreadyPaused() async throws {
        let context = makeContext()
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
        await context.setupPacketSender(sendPacketWithMetadata: { _, _, onComplete in
            pendingCompletions.withLock {
                $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete))
            }
        })
        let sender = try #require(await context.packetSender)
        await context.pauseForClientBackground()

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 4096),
                streamID: 9,
                frameNumber: 1,
                sequenceNumberStart: 10,
                generation: sender.currentGeneration
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.queuedByteCount > 0)
        #expect(!context.shouldEncodeFrames)

        await context.pauseForClientBackground()

        #expect(sender.queuedByteCount == 0)
        #expect(!context.shouldEncodeFrames)

        completePendingStreamPacketSends(pendingCompletions)
        await sender.stop()
    }

    @Test("Client foreground resume schedules reset keyframe and chain repair")
    func clientForegroundResumeSchedulesResetKeyframeAndChainRepair() async {
        let context = makeContext()
        await context.pauseForClientBackground()

        await context.resumeAfterClientForeground()

        #expect(context.shouldEncodeFrames)
        #expect(await context.pendingKeyframeReason == "Client foreground resume")
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeUrgent)
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)

        switch await context.frameChainState {
        case let .chainBroken(reason, _, _):
            #expect(reason == "client-foreground-resume")
        default:
            Issue.record("Expected foreground resume to enter frame-chain repair")
        }
    }

    @Test("Client foreground resume restores emergency visual quality before keyframe")
    func clientForegroundResumeRestoresEmergencyVisualQualityBeforeKeyframe() async {
        let context = makeContext(
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )
        let now = CFAbsoluteTimeGetCurrent()
        await context.applyAdaptiveRuntimeDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 12_000_000,
                maxFrameBytes: 64 * 1024,
                maxWireBytes: 64 * 1024,
                maxPacketCount: 64,
                quality: 0.04,
                qualityCeiling: 0.04,
                keyframeQuality: 0.04,
                sendDeadline: now + 1,
                state: .severe,
                reason: .clientRecovery
            ),
            now: now
        )
        #expect(await context.activeQuality >= 0.46)

        await context.pauseForClientBackground()
        await context.resumeAfterClientForeground()

        #expect(await context.activeQuality > 0.04)
        #expect(await context.keyframeQuality > 0.04)
        #expect(await context.pendingKeyframeReason == "Client foreground resume")
    }

    @Test("Constrained path keeps in-flight keyframe instead of queueing another")
    func constrainedPathKeepsInFlightKeyframe() async {
        let context = makeContext(transportPathKind: .awdl)

        await context.markKeyframeInFlight(frameNumber: 42)
        let firstDeadline = await context.keyframeSendDeadline
        try? await Task.sleep(for: .milliseconds(20))

        let queued = await context.queueKeyframe(
            reason: "Repeated recovery keyframe",
            checkInFlight: true,
            urgent: true
        )

        #expect(!queued)
        #expect(await context.keyframeInFlightFrameNumber == 42)
        #expect(await context.keyframeSendDeadline > firstDeadline)
    }

    @Test("Dependency drop recovery tracks retry diagnostics until keyframe")
    func dependencyDropRecoveryTracksRetryDiagnostics() async {
        let context = makeContext()
        await context.configureRunningForDependencyDropTest()

        await context.handlePacketSenderDependencyFrameDrop(
            streamID: 9,
            frameNumber: 7,
            reason: .queueEviction
        )

        #expect(await context.dependencyRecoveryPendingDropFrameNumber == 7)
        #expect(await context.dependencyRecoveryPendingDropReason == .queueEviction)
        #expect(await context.dependencyRecoveryPendingQueuedBytes == 0)
        #expect(await context.dependencyRecoveryRetryNecessary == false)

        await context.logDependencyRecoveryKeyframeIfNeeded(
            frameNumber: 8,
            queuedBytes: 1234
        )

        #expect(await context.dependencyRecoveryPendingDropFrameNumber == nil)
        #expect(await context.dependencyRecoveryPendingDropReason == nil)
        #expect(await context.dependencyRecoveryPendingQueuedBytes == 0)
        #expect(await context.dependencyRecoveryRetryNecessary == false)
    }

    private func makeContext(
        transportPathKind: MirageCore.MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 600_000_000
        )
        return StreamContext(
            streamID: 9,
            windowID: 9,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }
}

private extension StreamContext {
    func configureRunningForDependencyDropTest() {
        isRunning = true
    }
}
#endif
