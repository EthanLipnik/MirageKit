//
//  RuntimeQualityAdjustmentPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Runtime Quality Adjustment Policy")
struct RuntimeQualityAdjustmentPolicyTests {
    @Test("Delay-only bursts do not lower active quality")
    func delayOnlyBurstsDoNotLowerActiveQuality() {
        let assessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: 0,
                queueStressBytes: 1_200_000,
                queueSevereBytes: 2_000_000,
                packetBudgetUtilization: 0.04,
                packetBudgetStressThreshold: 1.05,
                packetBudgetSevereThreshold: 1.20,
                packetPacerAverageSleepMs: 0,
                packetPacerStressThresholdMs: 0.75,
                packetPacerSevereThresholdMs: 2.0,
                sendStartDelayAverageMs: 3.0,
                sendStartDelayStressThresholdMs: 1.0,
                sendStartDelaySevereThresholdMs: 4.0,
                sendCompletionAverageMs: 14.0,
                sendCompletionStressThresholdMs: 8.0,
                sendCompletionSevereThresholdMs: 16.0
            )
        )

        let decision = MirageRuntimeQualityAdjustmentPolicy.decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            qualityFloor: 0.28,
            qualityCeiling: 0.75,
            encodeOverBudget: false,
            packetWithinRaiseBudget: true,
            transportAssessment: assessment,
            allowEncodeDrivenQualityRelief: false,
            bitrateConstrained: true,
            adaptiveTransportRelief: true,
            qualityDropThreshold: 3,
            qualityRaiseThreshold: 4,
            qualityDropStep: 0.02,
            qualityDropStepHighPressure: 0.05,
            qualityRaiseStep: 0.03
        )

        #expect(assessment.isDelayOnlyBurst)
        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Queue pressure still lowers active quality")
    func queuePressureStillLowersActiveQuality() {
        let assessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: 1_350_000,
                queueStressBytes: 1_200_000,
                queueSevereBytes: 2_000_000,
                packetBudgetUtilization: 0.20,
                packetBudgetStressThreshold: 1.05,
                packetBudgetSevereThreshold: 1.20
            )
        )

        let decision = MirageRuntimeQualityAdjustmentPolicy.decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 1,
                qualityUnderBudgetCount: 0
            ),
            qualityFloor: 0.28,
            qualityCeiling: 0.75,
            encodeOverBudget: false,
            packetWithinRaiseBudget: true,
            transportAssessment: assessment,
            allowEncodeDrivenQualityRelief: false,
            bitrateConstrained: true,
            adaptiveTransportRelief: true,
            qualityDropThreshold: 3,
            qualityRaiseThreshold: 4,
            qualityDropStep: 0.02,
            qualityDropStepHighPressure: 0.05,
            qualityRaiseStep: 0.03
        )

        #expect(decision.action == .drop(reason: "queue"))
        #expect(abs(decision.state.activeQuality - 0.70) < 0.0001)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Packet pacer pressure still lowers active quality")
    func packetPacerPressureStillLowersActiveQuality() {
        let assessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: 0,
                queueStressBytes: 1_200_000,
                queueSevereBytes: 2_000_000,
                packetBudgetUtilization: 0.10,
                packetBudgetStressThreshold: 1.05,
                packetBudgetSevereThreshold: 1.20,
                packetPacerAverageSleepMs: 1.0,
                packetPacerStressThresholdMs: 0.75,
                packetPacerSevereThresholdMs: 2.0
            )
        )

        let decision = MirageRuntimeQualityAdjustmentPolicy.decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 1,
                qualityUnderBudgetCount: 0
            ),
            qualityFloor: 0.28,
            qualityCeiling: 0.75,
            encodeOverBudget: false,
            packetWithinRaiseBudget: true,
            transportAssessment: assessment,
            allowEncodeDrivenQualityRelief: false,
            bitrateConstrained: true,
            adaptiveTransportRelief: true,
            qualityDropThreshold: 3,
            qualityRaiseThreshold: 4,
            qualityDropStep: 0.02,
            qualityDropStepHighPressure: 0.05,
            qualityRaiseStep: 0.03
        )

        #expect(decision.action == .drop(reason: "pacer"))
        #expect(abs(decision.state.activeQuality - 0.70) < 0.0001)
    }
}
#endif
