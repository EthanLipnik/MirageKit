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
    @Test("Transport pressure is not a runtime quality drop signal")
    func transportPressureIsNotRuntimeQualityDropSignal() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            encodeOverBudget: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Encode overrun lowers active quality after consecutive samples")
    func encodeOverrunLowersActiveQualityAfterConsecutiveSamples() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            encodeOverBudget: true
        )

        #expect(decision.action == .drop(reason: "encode"))
        #expect(abs(decision.state.activeQuality - 0.73) < 0.0001)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Encode drop respects quality floor")
    func encodeDropRespectsQualityFloor() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.29,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            qualityFloor: 0.28,
            encodeOverBudget: true
        )

        #expect(decision.action == .drop(reason: "encode"))
        #expect(abs(decision.state.activeQuality - 0.28) < 0.0001)
    }

    @Test("Stable samples raise active quality after encode pressure clears")
    func stableSamplesRaiseActiveQualityAfterEncodePressureClears() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.66,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 3
            ),
            encodeOverBudget: false,
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
            encodeOverBudget: false,
            allowsRaise: false,
            qualityRaiseThreshold: 4
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.66)
        #expect(decision.state.qualityUnderBudgetCount == 0)
    }

    @Test("Encode-driven relief can be disabled")
    func encodeDrivenReliefCanBeDisabled() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            encodeOverBudget: true,
            allowEncodeDrivenQualityRelief: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Source cadence deficits suppress encode-driven quality drops")
    func sourceCadenceDeficitsSuppressEncodeDrivenQualityDrops() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            encodeOverBudget: true,
            sourceCadenceDeficient: true
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }


    private func decide(
        state: MirageRuntimeQualityAdjustmentState,
        qualityFloor: Float = 0.28,
        qualityCeiling: Float = 0.75,
        encodeOverBudget: Bool,
        sourceCadenceDeficient: Bool = false,
        allowsRaise: Bool = true,
        allowEncodeDrivenQualityRelief: Bool = true,
        qualityDropThreshold: Int = 3,
        qualityRaiseThreshold: Int = 4,
        qualityDropStep: Float = 0.02,
        qualityRaiseStep: Float = 0.03
    ) -> MirageRuntimeQualityAdjustmentDecision {
        MirageRuntimeQualityAdjustmentPolicy.decide(
            state: state,
            qualityFloor: qualityFloor,
            qualityCeiling: qualityCeiling,
            encodeOverBudget: encodeOverBudget,
            sourceCadenceDeficient: sourceCadenceDeficient,
            allowsRaise: allowsRaise,
            allowEncodeDrivenQualityRelief: allowEncodeDrivenQualityRelief,
            qualityDropThreshold: qualityDropThreshold,
            qualityRaiseThreshold: qualityRaiseThreshold,
            qualityDropStep: qualityDropStep,
            qualityRaiseStep: qualityRaiseStep
        )
    }
}
#endif
