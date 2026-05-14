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
    @Test("Clean transport is not a runtime quality drop signal")
    func cleanTransportIsNotRuntimeQualityDropSignal() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportPressure: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Transport pressure lowers active quality after consecutive samples")
    func transportPressureLowersActiveQualityAfterConsecutiveSamples() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportPressure: true
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
            transportPressure: true
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
            transportPressure: false,
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
            transportPressure: false,
            allowsRaise: false,
            qualityRaiseThreshold: 4
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.66)
        #expect(decision.state.qualityUnderBudgetCount == 0)
    }

    @Test("Encode overrun is not a quality drop signal")
    func encodeOverrunIsNotAQualityDropSignal() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportPressure: false
        )

        #expect(decision.action == .hold)
        #expect(decision.state.activeQuality == 0.75)
        #expect(decision.state.qualityOverBudgetCount == 0)
    }

    @Test("Source cadence deficits suppress transport quality drops")
    func sourceCadenceDeficitsSuppressTransportQualityDrops() {
        let decision = decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: 0.75,
                qualityOverBudgetCount: 2,
                qualityUnderBudgetCount: 0
            ),
            transportPressure: true,
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
        transportPressure: Bool,
        sourceCadenceDeficient: Bool = false,
        allowsRaise: Bool = true,
        qualityDropThreshold: Int = 3,
        qualityRaiseThreshold: Int = 4,
        qualityDropStep: Float = 0.02,
        qualityRaiseStep: Float = 0.03
    ) -> MirageRuntimeQualityAdjustmentDecision {
        MirageRuntimeQualityAdjustmentPolicy.decide(
            state: state,
            qualityFloor: qualityFloor,
            qualityCeiling: qualityCeiling,
            transportPressure: transportPressure,
            sourceCadenceDeficient: sourceCadenceDeficient,
            allowsRaise: allowsRaise,
            qualityDropThreshold: qualityDropThreshold,
            qualityRaiseThreshold: qualityRaiseThreshold,
            qualityDropStep: qualityDropStep,
            qualityRaiseStep: qualityRaiseStep
        )
    }
}
#endif
