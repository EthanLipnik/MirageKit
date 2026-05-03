//
//  HostCaptureCadenceRecoveryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Capture Cadence Recovery Policy")
struct HostCaptureCadenceRecoveryPolicyTests {
    @Test("Recovery is suppressed during startup and resize")
    func recoveryIsSuppressedDuringStartupAndResize() {
        var policy = policy(consecutiveBadWindowsRequired: 1)

        #expect(policy.evaluate(sample(now: 1, startupSettled: false)) == .none)
        #expect(policy.evaluate(sample(now: 2, isResizing: true)) == .none)
        #expect(policy.evaluate(sample(now: 3, isEncodingSuspendedForResize: true)) == .none)
    }

    @Test("Sustained bad capture cadence restarts SCStream first")
    func sustainedBadCaptureCadenceRestartsCaptureFirst() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        #expect(policy.evaluate(sample(now: 1)) == .none)
        #expect(policy.evaluate(sample(now: 3)) == .restartCapture)
    }

    @Test("Repeated bad windows escalate from restart to virtual display reassert")
    func repeatedBadWindowsEscalateToVirtualDisplayReassert() {
        var policy = policy(
            consecutiveBadWindowsRequired: 1,
            actionCooldownSeconds: 1,
            captureRestartsBeforeReassert: 2,
            virtualDisplayReassertsBeforeRecreate: 2
        )

        #expect(policy.evaluate(sample(now: 1)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 3)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 5)) == .reassertVirtualDisplayMode)
    }

    @Test("Repeated reassert failures eventually request virtual display recreation")
    func repeatedReassertFailuresRequestVirtualDisplayRecreation() {
        var policy = policy(
            consecutiveBadWindowsRequired: 1,
            actionCooldownSeconds: 1,
            captureRestartsBeforeReassert: 1,
            virtualDisplayReassertsBeforeRecreate: 1
        )

        #expect(policy.evaluate(sample(now: 1)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 3)) == .reassertVirtualDisplayMode)
        #expect(policy.evaluate(sample(now: 5)) == .recreateVirtualDisplay)
    }

    @Test("Cooldown prevents restart loops")
    func cooldownPreventsRestartLoops() {
        var policy = policy(consecutiveBadWindowsRequired: 1, actionCooldownSeconds: 8)

        #expect(policy.evaluate(sample(now: 1)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 2)) == .none)
    }

    @Test("Transport pressure blocks capture recovery")
    func transportPressureBlocksCaptureRecovery() {
        var policy = policy(consecutiveBadWindowsRequired: 1)
        var pressured = sample(now: 1)
        pressured.sendQueueBytes = 900_000
        pressured.queuePressureBytes = 1_200_000

        #expect(policy.evaluate(pressured) == .none)
    }

    private func policy(
        consecutiveBadWindowsRequired: Int,
        actionCooldownSeconds: Double = 0,
        captureRestartsBeforeReassert: Int = 2,
        virtualDisplayReassertsBeforeRecreate: Int = 2
    ) -> HostCaptureCadenceRecoveryPolicy {
        var policy = HostCaptureCadenceRecoveryPolicy()
        policy.configuration.consecutiveBadWindowsRequired = consecutiveBadWindowsRequired
        policy.configuration.actionCooldownSeconds = actionCooldownSeconds
        policy.configuration.captureRestartsBeforeReassert = captureRestartsBeforeReassert
        policy.configuration.virtualDisplayReassertsBeforeRecreate = virtualDisplayReassertsBeforeRecreate
        return policy
    }

    private func sample(
        now: Double,
        startupSettled: Bool = true,
        isResizing: Bool = false,
        isEncodingSuspendedForResize: Bool = false
    ) -> HostCaptureCadenceRecoveryPolicy.Sample {
        HostCaptureCadenceRecoveryPolicy.Sample(
            now: now,
            isDesktopDisplayStream: true,
            startupSettled: startupSettled,
            isResizing: isResizing,
            isEncodingSuspendedForResize: isEncodingSuspendedForResize,
            targetFrameRate: 60,
            captureFPS: 58,
            captureIngressFPS: 58,
            encodeAttemptFPS: 58,
            averageEncodeMs: 7,
            frameBudgetMs: 16.67,
            sendQueueBytes: 0,
            queuePressureBytes: 1_200_000,
            sendStartDelayMaxMs: 3,
            sendCompletionMaxMs: 10,
            packetPacerFrameMaxSleepMs: 1,
            captureCadence: StreamCaptureCadenceMetrics(
                wallClockGapWorstMs: 96,
                wallClockGapP95Ms: 48,
                wallClockGapP99Ms: 48,
                displayTimeGapWorstMs: 96,
                displayTimeGapP95Ms: 48,
                displayTimeGapP99Ms: 48,
                deliveredFrameGapWorstMs: 96,
                deliveredFrameGapP95Ms: 48,
                deliveredFrameGapP99Ms: 48,
                longFrameGapCount: 1
            )
        )
    }
}
#endif
