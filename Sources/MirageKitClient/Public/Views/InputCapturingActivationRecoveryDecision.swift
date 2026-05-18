//
//  InputCapturingActivationRecoveryDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

import Foundation
#if os(iOS) || os(visionOS)
import UIKit

struct InputCapturingActivationRecoveryDecision: Equatable {
    let shouldResetPresentationState: Bool
    let shouldRequestStreamRecovery: Bool
    let shouldResumeRenderingWithoutRecovery: Bool

    func merged(with other: Self) -> Self {
        let mergedShouldResetPresentationState = shouldResetPresentationState || other.shouldResetPresentationState
        let mergedShouldRequestStreamRecovery = shouldRequestStreamRecovery || other.shouldRequestStreamRecovery
        return InputCapturingActivationRecoveryDecision(
            shouldResetPresentationState: mergedShouldResetPresentationState,
            shouldRequestStreamRecovery: mergedShouldRequestStreamRecovery,
            shouldResumeRenderingWithoutRecovery: !mergedShouldRequestStreamRecovery &&
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

func inputCapturingCanApplyPendingActivationHandling(
    hasWindow: Bool,
    sceneActivationState: UIScene.ActivationState?
) -> Bool {
    guard hasWindow else { return false }
    return sceneActivationState == .foregroundActive
}

func inputCapturingCanApplyPendingDisplayActivationHandling(
    hasWindow: Bool,
    sceneActivationState: UIScene.ActivationState?
) -> Bool {
    guard hasWindow else { return false }
    return sceneActivationState == .foregroundActive ||
        sceneActivationState == .foregroundInactive
}

/// Outcome for a pending activation-recovery decision once the stream view is foregrounded again.
enum InputCapturingPendingActivationRecoveryDisposition {
    /// Apply the queued recovery handling to the active stream view.
    case applyPendingHandling
    /// Drop the queued handling because it no longer matches the active desktop session.
    case discardPendingHandling
}

/// Resolves whether delayed activation recovery still applies to the active desktop session.
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
    guard pendingDesktopSessionID == activeDesktopSessionID else {
        return .discardPendingHandling
    }
    return hasPresentedFrame ? .applyPendingHandling : .discardPendingHandling
}
#endif
