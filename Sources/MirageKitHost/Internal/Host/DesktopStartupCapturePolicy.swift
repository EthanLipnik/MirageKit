//
//  DesktopStartupCapturePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

import Foundation

#if os(macOS)

enum DisplayCaptureStartupReadiness: String, Sendable, Equatable {
    case usableFrameSeen
    case idleFrameSeen
    case blankOrSuspendedOnly
    case noScreenSamples
}

enum DesktopStartupCaptureRecoveryDecision: Equatable {
    case proceed
    case restartCapture
    case fail
}

func desktopStartupCaptureRecoveryDecision(
    readiness: DisplayCaptureStartupReadiness,
    recoveryAttempted: Bool,
    hasCachedStartupFrame: Bool = false,
    hasObservedStartupSample: Bool = false
) -> DesktopStartupCaptureRecoveryDecision {
    switch readiness {
    case .usableFrameSeen, .idleFrameSeen:
        return .proceed
    case .noScreenSamples where hasCachedStartupFrame || hasObservedStartupSample:
        return .proceed
    case .blankOrSuspendedOnly, .noScreenSamples:
        return recoveryAttempted ? .fail : .restartCapture
    }
}

enum StartupFrameReleaseDisposition: Equatable {
    case none
    case injectCachedFrame
}

func startupFrameReleaseDisposition(
    hasCachedFrame: Bool,
    hasQueuedFrame: Bool
) -> StartupFrameReleaseDisposition {
    guard hasCachedFrame, !hasQueuedFrame else { return .none }
    return .injectCachedFrame
}

func resolvedStartupFrameInjectionInfo(_ info: CapturedFrameInfo) -> CapturedFrameInfo {
    guard info.isIdleFrame else { return info }
    return CapturedFrameInfo(
        contentRect: info.contentRect,
        dirtyPercentage: info.dirtyPercentage,
        isIdleFrame: false
    )
}

#endif
