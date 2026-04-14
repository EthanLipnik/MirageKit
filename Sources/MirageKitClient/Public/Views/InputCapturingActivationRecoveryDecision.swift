//
//  InputCapturingActivationRecoveryDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

struct InputCapturingActivationRecoveryDecision: Equatable {
    let shouldResetPresentationState: Bool
    let shouldRequestStreamRecovery: Bool
    let shouldResumeRenderingWithoutRecovery: Bool

    func merged(with other: Self) -> Self {
        let shouldResetPresentationState = shouldResetPresentationState || other.shouldResetPresentationState
        let shouldRequestStreamRecovery = shouldRequestStreamRecovery || other.shouldRequestStreamRecovery
        return InputCapturingActivationRecoveryDecision(
            shouldResetPresentationState: shouldResetPresentationState,
            shouldRequestStreamRecovery: shouldRequestStreamRecovery,
            shouldResumeRenderingWithoutRecovery: !shouldRequestStreamRecovery &&
                (shouldResumeRenderingWithoutRecovery || other.shouldResumeRenderingWithoutRecovery)
        )
    }
}

func inputCapturingActivationRecoveryDecision(
    resignedActive: Bool,
    backgrounded: Bool,
    displayLayerFailed: Bool
) -> InputCapturingActivationRecoveryDecision {
    let shouldRequestRecovery = backgrounded || displayLayerFailed
    let shouldResumeWithoutRecovery = resignedActive && !shouldRequestRecovery
    return InputCapturingActivationRecoveryDecision(
        shouldResetPresentationState: shouldRequestRecovery,
        shouldRequestStreamRecovery: shouldRequestRecovery,
        shouldResumeRenderingWithoutRecovery: shouldResumeWithoutRecovery
    )
}
