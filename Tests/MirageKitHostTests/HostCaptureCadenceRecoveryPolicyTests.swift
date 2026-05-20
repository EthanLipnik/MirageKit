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

    @Test("Established stream cadence recovery restarts capture only")
    func establishedStreamCadenceRecoveryRestartsCaptureOnly() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        #expect(policy.evaluate(sample(now: 1)) == .none)
        #expect(policy.evaluate(sample(now: 3)) == .restartCapture)
    }

    @Test("Established stream cadence recovery does not escalate to virtual display topology")
    func establishedStreamCadenceRecoveryDoesNotEscalateToVirtualDisplayTopology() {
        var policy = policy(
            consecutiveBadWindowsRequired: 1,
            actionCooldownSeconds: 1,
            cadenceDriverRestartsBeforeReassert: 2,
            virtualDisplayReassertsBeforeRecreate: 2
        )

        #expect(policy.evaluate(sample(now: 1)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 3)) == .restartCapture)
        #expect(policy.evaluate(sample(now: 5)) == .restartCapture)
    }

    @Test("Pre-presentation cadence recovery may still use topology ladder")
    func prePresentationCadenceRecoveryMayStillUseTopologyLadder() {
        var policy = policy(
            consecutiveBadWindowsRequired: 1,
            actionCooldownSeconds: 1,
            cadenceDriverRestartsBeforeReassert: 1,
            virtualDisplayReassertsBeforeRecreate: 1
        )

        #expect(policy.evaluate(sample(now: 1, receiverHasPresentedFrame: false)) == .restartVirtualDisplayCadenceDriver)
        #expect(policy.evaluate(sample(now: 3, receiverHasPresentedFrame: false)) == .reassertVirtualDisplayMode)
        #expect(policy.evaluate(sample(now: 5, receiverHasPresentedFrame: false)) == .recreateVirtualDisplay)
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

    @Test("Healthy capture ingress ignores low encode attempt FPS")
    func healthyCaptureIngressIgnoresLowEncodeAttemptFPS() {
        var policy = policy(consecutiveBadWindowsRequired: 1)

        let action = policy.evaluate(
            sample(
                now: 1,
                captureFPS: 24,
                captureIngressFPS: 60,
                encodeAttemptFPS: 24,
                captureCadence: StreamCaptureCadenceMetrics()
            )
        )

        #expect(action == .none)
    }

    @Test("High refresh variable cadence above floor does not recover")
    func highRefreshVariableCadenceAboveFloorDoesNotRecover() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        let action = policy.evaluate(
            sample(
                now: 1,
                targetFrameRate: 120,
                captureFPS: 64,
                captureCadence: StreamCaptureCadenceMetrics(
                    deliveredFrameGapWorstMs: 22,
                    deliveredFrameGapP99Ms: 21,
                    usesDisplayRefreshCadence: true,
                    usesNativeRefreshMinimumFrameInterval: true,
                    minimumFrameIntervalRate: 120,
                    displayRefreshRate: 120,
                    virtualDisplayRefreshRate: 120
                )
            )
        )

        #expect(action == .none)
    }

    @Test("High refresh capture below floor restarts capture immediately")
    func highRefreshCaptureBelowFloorRestartsCaptureImmediately() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        let action = policy.evaluate(
            sample(
                now: 1,
                targetFrameRate: 120,
                captureFPS: 50,
                captureCadence: StreamCaptureCadenceMetrics(
                    deliveredFrameGapWorstMs: 22,
                    deliveredFrameGapP99Ms: 21,
                    usesDisplayRefreshCadence: true,
                    usesNativeRefreshMinimumFrameInterval: true,
                    minimumFrameIntervalRate: 120,
                    displayRefreshRate: 120,
                    virtualDisplayRefreshRate: 120
                )
            )
        )

        #expect(action == .restartCapture)
    }

    @Test("Established high refresh policy rate mismatch reasserts virtual display mode")
    func establishedHighRefreshPolicyRateMismatchReassertsVirtualDisplayMode() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        let action = policy.evaluate(
            sample(
                now: 1,
                targetFrameRate: 120,
                captureFPS: 64,
                captureCadence: StreamCaptureCadenceMetrics(
                    deliveredFrameGapWorstMs: 22,
                    deliveredFrameGapP99Ms: 21,
                    usesDisplayRefreshCadence: true,
                    usesNativeRefreshMinimumFrameInterval: true,
                    minimumFrameIntervalRate: 60,
                    displayRefreshRate: 60,
                    virtualDisplayRefreshRate: 120
                )
            )
        )

        #expect(action == .reassertVirtualDisplayMode)
        #expect(policy.lastSuppressedAction == nil)
        #expect(policy.lastSuppressionReason == nil)
    }

    @Test("Pre-presentation high refresh policy rate mismatch may reassert virtual display mode")
    func prePresentationHighRefreshPolicyRateMismatchMayReassertVirtualDisplayMode() {
        var policy = policy(consecutiveBadWindowsRequired: 2)

        let action = policy.evaluate(
            sample(
                now: 1,
                receiverHasPresentedFrame: false,
                targetFrameRate: 120,
                captureFPS: 64,
                captureCadence: StreamCaptureCadenceMetrics(
                    deliveredFrameGapWorstMs: 22,
                    deliveredFrameGapP99Ms: 21,
                    usesDisplayRefreshCadence: true,
                    usesNativeRefreshMinimumFrameInterval: true,
                    minimumFrameIntervalRate: 60,
                    displayRefreshRate: 60,
                    virtualDisplayRefreshRate: 120
                )
            )
        )

        #expect(action == .reassertVirtualDisplayMode)
    }

    @Test("High refresh healthy cadence does not recover")
    func highRefreshHealthyCadenceDoesNotRecover() {
        var policy = policy(consecutiveBadWindowsRequired: 1)

        let action = policy.evaluate(
            sample(
                now: 1,
                targetFrameRate: 120,
                captureFPS: 116,
                captureCadence: StreamCaptureCadenceMetrics(
                    deliveredFrameGapWorstMs: 12,
                    deliveredFrameGapP99Ms: 10,
                    usesDisplayRefreshCadence: true,
                    usesNativeRefreshMinimumFrameInterval: true,
                    minimumFrameIntervalRate: 120,
                    displayRefreshRate: 120,
                    virtualDisplayRefreshRate: 120
                )
            )
        )

        #expect(action == .none)
    }

    @Test("Presented high refresh stream recovers repeated thirty millisecond capture gaps")
    func presentedHighRefreshStreamRecoversRepeatedThirtyMillisecondCaptureGaps() {
        var policy = policy(consecutiveBadWindowsRequired: 2)
        let cadence = StreamCaptureCadenceMetrics(
            deliveredFrameGapWorstMs: 38,
            deliveredFrameGapP99Ms: 31,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 120,
            displayRefreshRate: 120,
            virtualDisplayRefreshRate: 120
        )

        let first = policy.evaluate(
            sample(now: 1, targetFrameRate: 120, captureFPS: 120, captureCadence: cadence)
        )
        let second = policy.evaluate(
            sample(now: 3, targetFrameRate: 120, captureFPS: 120, captureCadence: cadence)
        )

        #expect(first == .none)
        #expect(second == .restartCapture)
    }

    @Test("Presented sixty hertz stream recovers repeated thirty millisecond capture gaps")
    func presentedSixtyHertzStreamRecoversRepeatedThirtyMillisecondCaptureGaps() {
        var policy = policy(consecutiveBadWindowsRequired: 2)
        let cadence = StreamCaptureCadenceMetrics(
            deliveredFrameGapWorstMs: 38,
            deliveredFrameGapP99Ms: 31,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 60,
            displayRefreshRate: 60,
            virtualDisplayRefreshRate: 60
        )

        let first = policy.evaluate(
            sample(now: 1, targetFrameRate: 60, captureFPS: 60, captureCadence: cadence)
        )
        let second = policy.evaluate(
            sample(now: 3, targetFrameRate: 60, captureFPS: 60, captureCadence: cadence)
        )

        #expect(first == .none)
        #expect(second == .restartCapture)
    }

    @Test("Presented desktop severe capture stall recovers after one bad window")
    func presentedDesktopSevereCaptureStallRecoversAfterOneBadWindow() {
        var policy = policy(consecutiveBadWindowsRequired: 2)
        let cadence = StreamCaptureCadenceMetrics(
            deliveredFrameGapWorstMs: 520,
            deliveredFrameGapP99Ms: 20,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 60,
            displayRefreshRate: 60,
            virtualDisplayRefreshRate: 60
        )

        let action = policy.evaluate(
            sample(now: 1, targetFrameRate: 60, captureFPS: 60, captureCadence: cadence)
        )

        #expect(action == .restartCapture)
    }

    @Test("Pre-presentation severe capture stall keeps topology ladder")
    func prePresentationSevereCaptureStallKeepsTopologyLadder() {
        var policy = policy(
            consecutiveBadWindowsRequired: 1,
            cadenceDriverRestartsBeforeReassert: 1
        )
        let cadence = StreamCaptureCadenceMetrics(
            deliveredFrameGapWorstMs: 520,
            deliveredFrameGapP99Ms: 20,
            usesDisplayRefreshCadence: true,
            usesNativeRefreshMinimumFrameInterval: true,
            minimumFrameIntervalRate: 60,
            displayRefreshRate: 60,
            virtualDisplayRefreshRate: 60
        )

        let action = policy.evaluate(
            sample(
                now: 1,
                receiverHasPresentedFrame: false,
                targetFrameRate: 60,
                captureFPS: 60,
                captureCadence: cadence
            )
        )

        #expect(action == .restartVirtualDisplayCadenceDriver)
    }

    private func policy(
        consecutiveBadWindowsRequired: Int,
        actionCooldownSeconds: Double = 0,
        cadenceDriverRestartsBeforeReassert: Int = 2,
        captureRestartsBeforeReassert: Int = 0,
        virtualDisplayReassertsBeforeRecreate: Int = 2
    ) -> HostCaptureCadenceRecoveryPolicy {
        var policy = HostCaptureCadenceRecoveryPolicy()
        policy.configuration.consecutiveBadWindowsRequired = consecutiveBadWindowsRequired
        policy.configuration.actionCooldownSeconds = actionCooldownSeconds
        policy.configuration.cadenceDriverRestartsBeforeReassert = cadenceDriverRestartsBeforeReassert
        policy.configuration.captureRestartsBeforeReassert = captureRestartsBeforeReassert
        policy.configuration.virtualDisplayReassertsBeforeRecreate = virtualDisplayReassertsBeforeRecreate
        return policy
    }

    private func sample(
        now: Double,
        startupSettled: Bool = true,
        receiverHasPresentedFrame: Bool = true,
        isResizing: Bool = false,
        isEncodingSuspendedForResize: Bool = false,
        targetFrameRate: Int = 60,
        captureFPS: Double = 58,
        captureIngressFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        captureCadence: StreamCaptureCadenceMetrics? = nil
    ) -> HostCaptureCadenceRecoveryPolicy.Sample {
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFrameRate))
        return HostCaptureCadenceRecoveryPolicy.Sample(
            now: now,
            isDesktopDisplayStream: true,
            startupSettled: startupSettled,
            receiverHasPresentedFrame: receiverHasPresentedFrame,
            isResizing: isResizing,
            isEncodingSuspendedForResize: isEncodingSuspendedForResize,
            targetFrameRate: targetFrameRate,
            captureFPS: captureFPS,
            captureIngressFPS: captureIngressFPS ?? captureFPS,
            encodeAttemptFPS: encodeAttemptFPS ?? captureFPS,
            averageEncodeMs: 7,
            frameBudgetMs: frameBudgetMs,
            sendQueueBytes: 0,
            queuePressureBytes: 1_200_000,
            sendStartDelayMaxMs: 3,
            sendCompletionMaxMs: 10,
            packetPacerFrameMaxSleepMs: 1,
            captureCadence: captureCadence ?? StreamCaptureCadenceMetrics(
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
