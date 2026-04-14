//
//  InputCapturingActivationRecoveryDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

import Foundation

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

enum InputCapturingPendingActivationRecoveryDisposition: Equatable {
    case applyPendingHandling
    case clearPendingHandling
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

func inputCapturingPendingActivationRecoveryDisposition(
    activationDecision: InputCapturingActivationRecoveryDecision,
    pendingDesktopSessionID: UUID?,
    activeDesktopSessionID: UUID?,
    hasPresentedFrame: Bool
) -> InputCapturingPendingActivationRecoveryDisposition {
    guard activationDecision.shouldRequestStreamRecovery else {
        return .applyPendingHandling
    }
    guard let pendingDesktopSessionID else {
        return .applyPendingHandling
    }
    guard activeDesktopSessionID == pendingDesktopSessionID, hasPresentedFrame else {
        return .clearPendingHandling
    }
    return .applyPendingHandling
}
