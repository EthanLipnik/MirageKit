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

@Suite("Recovery Reason Mapping")
struct RecoveryReasonMappingTests {
    @Test("Fallback resume keyframe is urgent without reset or flush")
    func fallbackResumeDoesNotResetEpoch() async {
        let context = makeContext()

        await context.forceKeyframeAfterFallbackResume()

        #expect(await context.pendingKeyframeReason == "Fallback resume keyframe")
        #expect(await context.pendingKeyframeUrgent)
        #expect(await context.pendingKeyframeRequiresFlush == false)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(context.epoch == 0)
    }

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
            ignoreExistingInFlight: true
        )
        await context.requestKeyframeRecoveryIfPossible()

        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.softRecoveryCount == 0)
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
            reason: .expiredBeforeSend
        )

        #expect(await context.dependencyRecoveryPendingDropFrameNumber == 7)
        #expect(await context.dependencyRecoveryPendingDropReason == .expiredBeforeSend)
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

    private func makeContext(transportPathKind: MirageNetworkPathKind = .unknown) -> StreamContext {
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
            transportPathKind: transportPathKind
        )
    }
}

private extension StreamContext {
    func configureRunningForDependencyDropTest() {
        isRunning = true
    }
}
#endif
