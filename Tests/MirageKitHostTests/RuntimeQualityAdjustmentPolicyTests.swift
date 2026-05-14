//
//  RuntimeQualityAdjustmentPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Runtime Quality Adjustment Policy")
struct RuntimeQualityAdjustmentPolicyTests {
    @Test("Calm transport is not a runtime quality drop signal")
    func calmTransportIsNotRuntimeQualityDropSignal() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportOverBudget: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Transport overrun lowers active quality after consecutive samples")
    func transportOverrunLowersActiveQualityAfterConsecutiveSamples() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportOverBudget: true
        )

        #expect(decision.action == .drop(reason: "transport"))
        #expect(abs(decision.state.activeQuality - 0.73) < 0.0001)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Transport drop respects quality floor")
    func transportDropRespectsQualityFloor() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.29,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            qualityFloor: 0.28,
            transportOverBudget: true
        )

        #expect(decision.action == .drop(reason: "transport"))
        #expect(abs(decision.state.activeQuality - 0.28) < 0.0001)
    }

    @Test("Stable samples raise active quality after transport pressure clears")
    func stableSamplesRaiseActiveQualityAfterTransportPressureClears() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.66,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 3
            ),
            transportOverBudget: false,
            qualityRaiseThreshold: 4
        )

        #expect(decision.action == .raise)
        #expect(abs(decision.state.activeQuality - 0.69) < 0.0001)
        #expect(decision.state.qualityOverBudgetCount == 0)
        #expect(decision.state.qualityUnderBudgetCount == 0)
    }

    @Test("Raise gate holds active quality without carrying clean samples")
    func raiseGateHoldsActiveQualityWithoutCarryingCleanSamples() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.66,
                qualityOverBudgetCount: 0,
                qualityUnderBudgetCount: 3
            ),
            transportOverBudget: false,
            allowsRaise: false,
            qualityRaiseThreshold: 4
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.66)
        #expect(decision.state.qualityUnderBudgetCount == 0)
    }

    @Test("Transport-driven relief can be disabled")
    func transportDrivenReliefCanBeDisabled() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportOverBudget: true,
            allowTransportQualityRelief: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    private func decide(
        state: MirageRuntimeQualityAdjustmentState,
        qualityFloor: Float = 0.28,
        qualityCeiling: Float = 0.75,
        transportOverBudget: Bool,
        allowsRaise: Bool = true,
        allowTransportQualityRelief: Bool = true,
        qualityDropThreshold: Int = 3,
        qualityRaiseThreshold: Int = 4,
        qualityDropStep: Float = 0.02,
        qualityRaiseStep: Float = 0.03
    ) -> MirageRuntimeQualityAdjustmentDecision {
        MirageRuntimeQualityAdjustmentPolicy.decide(
            state: state,
            qualityFloor: qualityFloor,
            qualityCeiling: qualityCeiling,
            transportOverBudget: transportOverBudget,
            allowsRaise: allowsRaise,
            allowTransportQualityRelief: allowTransportQualityRelief,
            qualityDropThreshold: qualityDropThreshold,
            qualityRaiseThreshold: qualityRaiseThreshold,
            qualityDropStep: qualityDropStep,
            qualityRaiseStep: qualityRaiseStep
        )
    }
}
#endif
