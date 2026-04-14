//
//  InputCapturingActivationRecoveryDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

@testable import MirageKitClient
import Testing

@Suite("Input Capturing Activation Recovery Decision")
struct InputCapturingActivationRecoveryDecisionTests {
    @Test("Resigned-active only resumes rendering without stream recovery")
    func resignedActiveOnlyResumesRenderingWithoutStreamRecovery() {
        let decision = inputCapturingActivationRecoveryDecision(
            resignedActive: true,
            backgrounded: false,
            displayLayerFailed: false
        )

        #expect(decision.shouldResetPresentationState == false)
        #expect(decision.shouldRequestStreamRecovery == false)
        #expect(decision.shouldResumeRenderingWithoutRecovery)
    }

    @Test("Backgrounded activation resets presentation and requests recovery")
    func backgroundedActivationResetsPresentationAndRequestsRecovery() {
        let decision = inputCapturingActivationRecoveryDecision(
            resignedActive: false,
            backgrounded: true,
            displayLayerFailed: false
        )

        #expect(decision.shouldResetPresentationState)
        #expect(decision.shouldRequestStreamRecovery)
        #expect(decision.shouldResumeRenderingWithoutRecovery == false)
    }

    @Test("Display-layer failure resets presentation and requests recovery")
    func displayLayerFailureResetsPresentationAndRequestsRecovery() {
        let decision = inputCapturingActivationRecoveryDecision(
            resignedActive: false,
            backgrounded: false,
            displayLayerFailed: true
        )

        #expect(decision.shouldResetPresentationState)
        #expect(decision.shouldRequestStreamRecovery)
        #expect(decision.shouldResumeRenderingWithoutRecovery == false)
    }

    @Test("Backgrounded display-layer failure keeps recovery required")
    func backgroundedDisplayLayerFailureKeepsRecoveryRequired() {
        let decision = inputCapturingActivationRecoveryDecision(
            resignedActive: true,
            backgrounded: true,
            displayLayerFailed: true
        )

        #expect(decision.shouldResetPresentationState)
        #expect(decision.shouldRequestStreamRecovery)
        #expect(decision.shouldResumeRenderingWithoutRecovery == false)
    }
}
