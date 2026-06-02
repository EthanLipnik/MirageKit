//
//  MirageAwdlMediaControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//
//  Coverage for the central AWDL realtime display policy.
//

@testable import MirageKit
import Testing

@Suite("AWDL Media Controller")
struct MirageAwdlMediaControllerTests {
    @Test("AWDL stable startup uses realtime defaults")
    func awdlStableStartupUsesRealtimeDefaults() {
        var controller = MirageAwdlMediaController()

        let decision = controller.update(
            with: MirageAwdlMediaController.Signal(
                mediaPathProfile: .awdlRadio,
                currentFrameRate: 120,
                targetFrameRate: 120,
                targetBitrateBps: 48_000_000
            )
        )

        #expect(decision.state == .starting)
        #expect(decision.trigger == .stable)
        #expect(decision.targetFrameRate == 60)
        #expect(decision.hostPacingBudgetBps == 32_000_000)
        #expect(decision.keyframePacingBudgetBps == 48_000_000)
        #expect(decision.pFramePacketBurst == 2)
        #expect(decision.keyframePacketBurst == 4)
        #expect(decision.pFrameFECBlockSize == 0)
        #expect(decision.keyframeFECBlockSize == 4)
        #expect(decision.continuityWindowMs == MirageAwdlMediaController.baseContinuityWindowMs)
        #expect(decision.playoutDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
        #expect(decision.resolutionScale == 1.0)
        #expect(decision.selectedLever == .observe)
        #expect(
            MirageAwdlMediaController.fixedLatencyMode(
                requestedLatencyMode: .smoothest,
                mediaPathProfile: .awdlRadio
            ) == .balanced
        )
    }

    @Test("Stable AWDL samples settle the controller into steady")
    func stableAwdlSamplesSettleControllerIntoSteady() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60
        )

        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .steady)
        #expect(decision.trigger == .stable)
    }

    @Test("AWDL jitter grows playout")
    func awdlJitterGrowsPlayout() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            jitterP99Ms: 90
        )

        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .stressed)
        #expect(decision.trigger == .jitter)
        #expect(decision.targetFrameRate == 45)
        #expect(decision.playoutDelayMs == 64)
        #expect(decision.selectedLever == .frameRate)
    }

    @Test("AWDL completed receive gaps alone do not become radio jitter")
    func awdlCompletedReceiveGapsAloneDoNotBecomeRadioJitter() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(receivedWorstGapMs: 240),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )

        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .steady)
        #expect(decision.trigger == .stable)
        #expect(decision.targetFrameRate == 60)
        #expect(decision.playoutDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
        #expect(decision.selectedLever == .observe)
    }

    @Test("AWDL non-recovery stress playout stays inside stress window")
    func awdlNonRecoveryStressPlayoutStaysInsideStressWindow() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            jitterP99Ms: 190
        )

        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .stressed)
        #expect(decision.trigger == .jitter)
        #expect(decision.playoutDelayMs == MirageAwdlMediaController.stableMaximumPlayoutDelayMs)
        #expect(decision.selectedLever == .frameRate)
    }

    @Test("AWDL recovery playout can briefly use maximum window")
    func awdlRecoveryPlayoutCanBrieflyUseMaximumWindow() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(recoveryState: .hardRecovery),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )

        let decision = controller.update(with: signal)

        #expect(decision.state == .failed)
        #expect(decision.trigger == .recovery)
        #expect(decision.playoutDelayMs == MirageAwdlMediaController.maximumPlayoutDelayMs)
        #expect(decision.selectedLever == .recovery)
    }

    @Test("Sustained AWDL jitter enters demotion ladder before quality reduction")
    func sustainedAwdlJitterEntersDemotionLadderBeforeQualityReduction() {
        var controller = MirageAwdlMediaController()
        let sixtyFPSPressure = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            jitterP99Ms: 130
        )

        _ = controller.update(with: sixtyFPSPressure)
        _ = controller.update(with: sixtyFPSPressure)
        _ = controller.update(with: sixtyFPSPressure)
        let cadenceDecision = controller.update(with: sixtyFPSPressure)

        #expect(cadenceDecision.state == .demoted)
        #expect(cadenceDecision.trigger == .jitter)
        #expect(cadenceDecision.targetFrameRate == 45)
        #expect(cadenceDecision.resolutionScale == 1.0)
        #expect(!cadenceDecision.qualityReductionAllowed)
        #expect(cadenceDecision.selectedLever == .frameRate)

        let fortyFiveFPSPressure = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 45,
            targetFrameRate: 60,
            jitterP99Ms: 130
        )
        let secondCadenceDecision = controller.update(with: fortyFiveFPSPressure)

        #expect(secondCadenceDecision.targetFrameRate == 30)
        #expect(secondCadenceDecision.resolutionScale == 1.0)
        #expect(!secondCadenceDecision.qualityReductionAllowed)
        #expect(secondCadenceDecision.selectedLever == .frameRate)

        let thirtyFPSPressure = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 30,
            targetFrameRate: 60,
            jitterP99Ms: 130
        )
        let resolutionDecision = controller.update(with: thirtyFPSPressure)

        #expect(resolutionDecision.targetFrameRate == 30)
        #expect(resolutionDecision.resolutionScale == 0.875)
        #expect(!resolutionDecision.qualityReductionAllowed)
        #expect(resolutionDecision.selectedLever == .resolution)

        _ = controller.update(with: thirtyFPSPressure)
        let survivalDecision = controller.update(with: thirtyFPSPressure)

        #expect(survivalDecision.targetFrameRate == 30)
        #expect(survivalDecision.resolutionScale == 0.75)
        #expect(survivalDecision.qualityReductionAllowed)
        #expect(survivalDecision.selectedLever == .quality)
    }

    @Test("AWDL playout stress growth is bounded and decays after stable samples")
    func awdlPlayoutStressGrowthIsBoundedAndDecaysAfterStableSamples() {
        var controller = MirageAwdlMediaController()
        let stressSignal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            jitterP99Ms: 260
        )
        let stableSignal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60
        )

        _ = controller.update(with: stressSignal)
        let stressed = controller.update(with: stressSignal)
        #expect(stressed.playoutDelayMs == MirageAwdlMediaController.stableMaximumPlayoutDelayMs)

        let firstStable = controller.update(with: stableSignal)
        #expect(firstStable.playoutDelayMs <= MirageAwdlMediaController.stableMaximumPlayoutDelayMs)

        var decayed = firstStable
        for _ in 0 ..< 12 {
            decayed = controller.update(with: stableSignal)
        }
        #expect(decayed.state == .steady)
        #expect(decayed.playoutDelayMs == MirageAwdlMediaController.basePlayoutDelayMs)
    }

    @Test("AWDL stable samples restore to explicit frame-rate ceiling after sustained stability")
    func awdlStableSamplesRestoreToExplicitFrameRateCeilingAfterSustainedStability() {
        var controller = MirageAwdlMediaController()
        let pressureSignal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            requestedFrameRateCeiling: 60,
            jitterP99Ms: 130
        )

        _ = controller.update(with: pressureSignal)
        _ = controller.update(with: pressureSignal)
        _ = controller.update(with: pressureSignal)
        let demoted = controller.update(with: pressureSignal)
        #expect(demoted.targetFrameRate == 45)

        let stableDemotedFeedback = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 45,
            targetFrameRate: 45,
            requestedFrameRateCeiling: 60
        )
        let restoring = controller.update(with: stableDemotedFeedback)

        #expect(restoring.trigger == .stable)
        #expect(restoring.state == .demoted)
        #expect(restoring.targetFrameRate == 45)

        _ = controller.update(with: stableDemotedFeedback)
        let restored = controller.update(with: stableDemotedFeedback)

        #expect(restored.state == .steady)
        #expect(restored.targetFrameRate == 60)
        #expect(restored.resolutionScale == 1.0)
    }

    @Test("AWDL late P-frame pressure grows continuity")
    func awdlLatePFramePressureGrowsContinuity() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 220,
            latePFrameCount: 4
        )

        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .stressed)
        #expect(decision.trigger == .pFrameLatency)
        #expect(decision.continuityWindowMs == MirageAwdlMediaController.maximumContinuityWindowMs)
    }

    @Test("AWDL P-frame latency stress respects receiver playout target")
    func awdlPFrameLatencyStressRespectsReceiverPlayoutTarget() {
        var stableController = MirageAwdlMediaController()
        let smoothedSignal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 90,
            receiverPlayoutDelayTargetMs: 120
        )

        _ = stableController.update(with: smoothedSignal)
        let stableDecision = stableController.update(with: smoothedSignal)

        #expect(stableDecision.trigger == .stable)
        #expect(stableDecision.targetFrameRate == 60)

        var stressedController = MirageAwdlMediaController()
        let lateSignal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 150,
            receiverPlayoutDelayTargetMs: 120
        )

        _ = stressedController.update(with: lateSignal)
        let stressedDecision = stressedController.update(with: lateSignal)

        #expect(stressedDecision.trigger == .pFrameLatency)
        #expect(stressedDecision.targetFrameRate == 45)
    }

    @Test("Healthy AWDL presentation queue is not treated as backlog")
    func healthyAwdlPresentationQueueIsNotTreatedAsBacklog() {
        let feedback = receiverFeedback(
            presentationQueueDepth: 5,
            presentationTargetFrames: 5
        )
        let signal = MirageAwdlMediaController.Signal(
            feedback: feedback,
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var controller = MirageAwdlMediaController()

        #expect(signal.presentationBacklogFrames == 0)
        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .steady)
        #expect(decision.trigger == .stable)
    }

    @Test("AWDL presentation backlog and underfill remain distinct triggers")
    func awdlPresentationBacklogAndUnderfillRemainDistinctTriggers() {
        let backlogSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(
                presentationQueueDepth: 9,
                presentationTargetFrames: 5
            ),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var backlogController = MirageAwdlMediaController()
        _ = backlogController.update(with: backlogSignal)
        let backlogDecision = backlogController.update(with: backlogSignal)
        #expect(backlogSignal.presentationBacklogFrames == 4)
        #expect(backlogDecision.state == .stressed)
        #expect(backlogDecision.trigger == .presentationBacklog)
        #expect(backlogDecision.targetFrameRate == 45)

        let underfillSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(presentationUnderfillFrames: 2),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var underfillController = MirageAwdlMediaController()
        _ = underfillController.update(with: underfillSignal)
        let underfillDecision = underfillController.update(with: underfillSignal)
        #expect(underfillSignal.presentationBacklogFrames == 0)
        #expect(underfillDecision.trigger == .stable)
        #expect(underfillDecision.targetFrameRate == 60)

        let fillDeficitSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(presentationFillDeficitFrames: 3),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var fillDeficitController = MirageAwdlMediaController()
        _ = fillDeficitController.update(with: fillDeficitSignal)
        let fillDeficitDecision = fillDeficitController.update(with: fillDeficitSignal)
        #expect(fillDeficitSignal.presentationFillDeficitFrames == 3)
        #expect(fillDeficitDecision.state == .stressed)
        #expect(fillDeficitDecision.trigger == .presentationFillDeficit)
        #expect(fillDeficitDecision.selectedLever == .playout)
        #expect(fillDeficitDecision.targetFrameRate == 60)

        let visibleUnderflowSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(
                presentationUnderfillFrames: 2,
                displayTickNoFrameCount: 3
            ),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var visibleUnderflowController = MirageAwdlMediaController()
        _ = visibleUnderflowController.update(with: visibleUnderflowSignal)
        let visibleUnderflowDecision = visibleUnderflowController.update(with: visibleUnderflowSignal)
        #expect(visibleUnderflowDecision.state == .stressed)
        #expect(visibleUnderflowDecision.trigger == .presentationUnderflow)
        #expect(visibleUnderflowDecision.targetFrameRate == 45)

        let notReadyUnderflowSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(pendingFrameNotReadyDisplayTickCount: 3),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var notReadyUnderflowController = MirageAwdlMediaController()
        _ = notReadyUnderflowController.update(with: notReadyUnderflowSignal)
        let notReadyUnderflowDecision = notReadyUnderflowController.update(with: notReadyUnderflowSignal)
        #expect(notReadyUnderflowDecision.state == .stressed)
        #expect(notReadyUnderflowDecision.trigger == .presentationUnderflow)
        #expect(notReadyUnderflowDecision.targetFrameRate == 45)
    }

    @Test("AWDL forward-gap timeout enters recovery without admission throttling")
    func awdlForwardGapTimeoutEntersRecoveryWithoutAdmissionThrottling() {
        var controller = MirageAwdlMediaController()

        let decision = controller.update(
            with: MirageAwdlMediaController.Signal(
                mediaPathProfile: .awdlRadio,
                currentFrameRate: 60,
                targetFrameRate: 60,
                forwardGapTimeouts: 1
            )
        )

        #expect(decision.state == .recovering)
        #expect(decision.trigger == .recovery)
        #expect(decision.pFrameFECBlockSize == 4)
        #expect(decision.keyframeFECBlockSize == 4)
        #expect(MirageAwdlMediaController.startupKeyframeFECBlockSizeForAwdlRadio() == 4)
        #expect(MirageAwdlMediaController.pFrameFECBlockSize(
            frameByteCount: 1_200,
            maxPayloadSize: 1_200,
            isLossModeActive: false
        ) == 0)
    }

    @Test("AWDL startup feedback enters awaiting-first-frame policy")
    func awdlStartupFeedbackEntersAwaitingFirstFramePolicy() {
        var controller = MirageAwdlMediaController()

        let decision = controller.update(
            with: MirageAwdlMediaController.Signal(
                feedback: receiverFeedback(recoveryState: .startup),
                currentFrameRate: 60,
                mediaPathProfile: .awdlRadio
            )
        )

        #expect(decision.state == .awaitingFirstFrame)
        #expect(decision.trigger == .startup)
        #expect(decision.targetFrameRate == 45)
        #expect(decision.pFrameFECBlockSize == 4)
        #expect(!decision.qualityReductionAllowed)
    }

    @Test("AWDL hard recovery enters failed survival policy")
    func awdlHardRecoveryEntersFailedSurvivalPolicy() {
        var controller = MirageAwdlMediaController()

        let decision = controller.update(
            with: MirageAwdlMediaController.Signal(
                feedback: receiverFeedback(recoveryState: .hardRecovery),
                currentFrameRate: 60,
                mediaPathProfile: .awdlRadio
            )
        )

        #expect(decision.state == .failed)
        #expect(decision.trigger == .recovery)
        #expect(decision.targetFrameRate == 30)
        #expect(decision.pFrameFECBlockSize == 4)
        #expect(!decision.qualityReductionAllowed)
    }

    @Test("Sustained AWDL pressure demotes cadence and resolution before quality")
    func sustainedAwdlPressureDemotesCadenceAndResolutionBeforeQuality() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 80,
            latePFrameCount: 4
        )

        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .demoted)
        #expect(decision.trigger == .pFrameLatency)
        #expect(decision.targetFrameRate == 45)
        #expect(decision.resolutionScale == 1.0)
        #expect(!decision.qualityReductionAllowed)
        #expect(decision.selectedLever == .frameRate)
    }

    @Test("AWDL survival requires sustained pressure after demotion")
    func awdlSurvivalRequiresSustainedPressureAfterDemotion() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 60,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 80,
            latePFrameCount: 4
        )

        for _ in 0 ..< 4 {
            _ = controller.update(with: signal)
        }
        let fortyFiveFPSPressure = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 45,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 80,
            latePFrameCount: 4
        )
        _ = controller.update(with: fortyFiveFPSPressure)
        let thirtyFPSPressure = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 30,
            targetFrameRate: 60,
            pFrameCompletionLatencyP95Ms: 80,
            latePFrameCount: 4
        )
        _ = controller.update(with: thirtyFPSPressure)
        _ = controller.update(with: thirtyFPSPressure)
        let decision = controller.update(with: thirtyFPSPressure)

        #expect(decision.state == .demoted)
        #expect(decision.trigger == .pFrameLatency)
        #expect(decision.targetFrameRate == 30)
        #expect(decision.resolutionScale == 0.75)
        #expect(decision.qualityReductionAllowed)
        #expect(decision.selectedLever == .quality)
    }

    @Test("AWDL saturated decode submissions trigger decode pressure when throughput lags")
    func awdlSaturatedDecodeSubmissionsTriggerDecodePressureWhenThroughputLags() {
        let signal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(
                decodedFPS: 42,
                receivedFPS: 60,
                decodeSubmissionLimit: 2,
                inFlightDecodeSubmissions: 2
            ),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var controller = MirageAwdlMediaController()
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .stressed)
        #expect(decision.trigger == .decodePressure)
        #expect(decision.targetFrameRate == 45)

        let unsaturatedSignal = MirageAwdlMediaController.Signal(
            feedback: receiverFeedback(
                decodedFPS: 42,
                receivedFPS: 60,
                decodeSubmissionLimit: 3,
                inFlightDecodeSubmissions: 1
            ),
            currentFrameRate: 60,
            mediaPathProfile: .awdlRadio
        )
        var unsaturatedController = MirageAwdlMediaController()
        _ = unsaturatedController.update(with: unsaturatedSignal)
        let unsaturatedDecision = unsaturatedController.update(with: unsaturatedSignal)

        #expect(unsaturatedDecision.trigger == .stable)
    }

    private func receiverFeedback(
        decodedFPS: Double = 60,
        receivedFPS: Double = 60,
        decodeSubmissionLimit: Int? = nil,
        inFlightDecodeSubmissions: Int? = nil,
        receivedWorstGapMs: Double? = nil,
        presentationQueueDepth: Int? = nil,
        presentationTargetFrames: Int? = nil,
        presentationFillDeficitFrames: Int? = nil,
        presentationUnderfillFrames: Int? = nil,
        displayTickNoFrameCount: UInt64? = nil,
        pendingFrameNotReadyDisplayTickCount: UInt64? = nil,
        recoveryState: MirageMediaFeedbackRecoveryState = .idle
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: 1,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            lostFrameCount: 0,
            discardedPacketCount: 0,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: 0,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: 0,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: recoveryState,
            receivedWorstGapMs: receivedWorstGapMs,
            displayTickNoFrameCount: displayTickNoFrameCount,
            pendingFrameNotReadyDisplayTickCount: pendingFrameNotReadyDisplayTickCount,
            decodeSubmissionLimit: decodeSubmissionLimit,
            inFlightDecodeSubmissions: inFlightDecodeSubmissions,
            presentationQueueDepth: presentationQueueDepth,
            presentationTargetFrames: presentationTargetFrames,
            presentationFillDeficitFrames: presentationFillDeficitFrames,
            presentationUnderfillFrames: presentationUnderfillFrames
        )
    }
}
