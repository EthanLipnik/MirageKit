//
//  RecoveryReasonAndBackoffTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Coverage for capture restart backoff and recovery-reason keyframe behavior.
//

@testable import MirageKitHost
import MirageKit
import Foundation
import Testing

#if os(macOS)
@Suite("Capture Restart Backoff")
struct CaptureRestartBackoffTests {
    @Test("Restart cooldown backs off and caps")
    func restartCooldownBackoffAndCap() {
        #expect(WindowCaptureEngine.restartCooldown(for: 1) == 3.0)
        #expect(WindowCaptureEngine.restartCooldown(for: 2) == 6.0)
        #expect(WindowCaptureEngine.restartCooldown(for: 3) == 12.0)
        #expect(WindowCaptureEngine.restartCooldown(for: 4) == 18.0)
        #expect(WindowCaptureEngine.restartCooldown(for: 5) == 18.0)
    }

    @Test("Restart escalation threshold triggers at streak three")
    func restartEscalationThreshold() {
        #expect(WindowCaptureEngine.shouldEscalateRecovery(restartStreak: 1, threshold: 3) == false)
        #expect(WindowCaptureEngine.shouldEscalateRecovery(restartStreak: 2, threshold: 3) == false)
        #expect(WindowCaptureEngine.shouldEscalateRecovery(restartStreak: 3, threshold: 3))
        #expect(WindowCaptureEngine.shouldEscalateRecovery(restartStreak: 4, threshold: 3))
    }

    @Test("Restart streak reset window requires stable interval")
    func restartStreakResetWindow() {
        let now: CFAbsoluteTime = 100
        #expect(
            WindowCaptureEngine.shouldResetRestartStreak(
                now: now,
                lastRestartAttemptTime: now - 21,
                resetWindow: 20
            )
        )
        #expect(
            WindowCaptureEngine.shouldResetRestartStreak(
                now: now,
                lastRestartAttemptTime: now - 19,
                resetWindow: 20
            ) == false
        )
        #expect(
            WindowCaptureEngine.shouldResetRestartStreak(
                now: now,
                lastRestartAttemptTime: 0,
                resetWindow: 20
            ) == false
        )
    }

    @Test("Resumed stall signal cancels pending capture restart")
    func resumedStallSignalCancelsPendingRestart() async {
        let engine = WindowCaptureEngine(
            configuration: MirageEncoderConfiguration(targetFrameRate: 60),
            latencyMode: .auto,
            captureFrameRate: 60
        )
        await engine.setCaptureStateForTesting(isCapturing: true, captureMode: .display)
        await engine.scheduleCaptureRestart(reason: "test-stall", debounce: 1.0)
        #expect(await engine.hasScheduledCaptureRestartForTesting())

        await engine.handleCaptureStallSignal(
            CaptureStreamOutput.StallSignal(
                stage: .resumed,
                message: "stall resumed",
                gapMs: "1200.0",
                softThresholdMs: "1000.0",
                hardThresholdMs: "1200.0",
                restartEligible: false
            )
        )

        #expect(await engine.hasScheduledCaptureRestartForTesting() == false)
    }
}

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

        let escalated = makeContext()
        await escalated.forceKeyframeAfterCaptureRestart(
            restartStreak: 3,
            shouldEscalateRecovery: true
        )
        #expect(await escalated.pendingKeyframeRequiresFlush)
        #expect(await escalated.pendingKeyframeRequiresReset)
        #expect(escalated.epoch == 1)
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
        await context.requestKeyframe()

        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.softRecoveryCount == 0)
        #expect(await context.hardRecoveryCount == 0)
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
            streamID: 9,
            windowID: 9,
            encoderConfig: encoderConfig,
            streamScale: 1.0
        )
    }
}
#endif
