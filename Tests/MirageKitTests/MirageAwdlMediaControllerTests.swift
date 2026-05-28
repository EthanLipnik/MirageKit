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

        #expect(decision.state == .warmup)
        #expect(decision.trigger == .stable)
        #expect(decision.targetFrameRate == 60)
        #expect(decision.hostPacingBudgetBps == 24_000_000)
        #expect(decision.keyframePacingBudgetBps == 24_000_000)
        #expect(decision.pFramePacketBurst == 2)
        #expect(decision.keyframePacketBurst == 4)
        #expect(decision.pFrameFECBlockSize == 0)
        #expect(decision.keyframeFECBlockSize == 4)
        #expect(decision.continuityWindowMs == 180)
        #expect(decision.playoutDelayMs == 24)
        #expect(decision.allowFrameAdmissionReduction == false)
        #expect(decision.frameAdmissionTargetFPS == nil)
        #expect(
            MirageAwdlMediaController.fixedLatencyMode(
                requestedLatencyMode: .smoothest,
                mediaPathProfile: .awdlRadio
            ) == .lowestLatency
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
        #expect(decision.frameAdmissionTargetFPS == nil)
    }

    @Test("AWDL jitter grows playout without pre-encode admission")
    func awdlJitterGrowsPlayoutWithoutPreEncodeAdmission() {
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
        #expect(decision.playoutDelayMs == 64)
        #expect(decision.allowFrameAdmissionReduction == false)
        #expect(decision.frameAdmissionTargetFPS == nil)
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
        #expect(stressed.playoutDelayMs == 180)

        let firstStable = controller.update(with: stableSignal)
        #expect(firstStable.playoutDelayMs <= 80)

        var decayed = firstStable
        for _ in 0 ..< 12 {
            decayed = controller.update(with: stableSignal)
        }
        #expect(decayed.state == .steady)
        #expect(decayed.playoutDelayMs == 24)
    }

    @Test("AWDL late P-frame pressure grows continuity and reduces admission")
    func awdlLatePFramePressureGrowsContinuityAndReducesAdmission() {
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
        #expect(decision.continuityWindowMs == 300)
        #expect(decision.allowFrameAdmissionReduction)
        #expect(decision.frameAdmissionTargetFPS == 30)
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

        #expect(decision.state == .recovery)
        #expect(decision.trigger == .recovery)
        #expect(decision.pFrameFECBlockSize == 4)
        #expect(decision.keyframeFECBlockSize == 4)
        #expect(MirageAwdlMediaController.startupKeyframeFECBlockSizeForAwdlRadio() == 4)
        #expect(MirageAwdlMediaController.pFrameFECBlockSize(
            frameByteCount: 1_200,
            maxPayloadSize: 1_200,
            isLossModeActive: false
        ) == 0)
        #expect(decision.allowFrameAdmissionReduction == false)
        #expect(decision.frameAdmissionTargetFPS == nil)
    }

    @Test("Sustained high-refresh AWDL pressure demotes to sixty")
    func sustainedHighRefreshAwdlPressureDemotesToSixty() {
        var controller = MirageAwdlMediaController()
        let signal = MirageAwdlMediaController.Signal(
            mediaPathProfile: .awdlRadio,
            currentFrameRate: 120,
            targetFrameRate: 120,
            pFrameCompletionLatencyP95Ms: 80,
            latePFrameCount: 4
        )

        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        _ = controller.update(with: signal)
        let decision = controller.update(with: signal)

        #expect(decision.state == .demote)
        #expect(decision.trigger == .demote)
        #expect(decision.targetFrameRate == 60)
        #expect(decision.qualityReductionAllowed)
        #expect(decision.frameAdmissionTargetFPS == 60)
    }
}
