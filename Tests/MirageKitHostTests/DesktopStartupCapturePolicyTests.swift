//
//  DesktopStartupCapturePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Desktop Startup Capture Policy")
struct DesktopStartupCapturePolicyTests {
    @Test("Readiness with usable or idle samples proceeds without recovery")
    func readinessProceedStatesDoNotRestart() {
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .usableFrameSeen,
                recoveryAttempted: false
            ) == .proceed
        )
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .idleFrameSeen,
                recoveryAttempted: true
            ) == .proceed
        )
    }

    @Test("Blank or missing startup samples restart once before policy failure")
    func readinessFailureStatesRestartOnceThenFail() {
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .blankOrSuspendedOnly,
                recoveryAttempted: false
            ) == .restartCapture
        )
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .noScreenSamples,
                recoveryAttempted: false
            ) == .restartCapture
        )
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .blankOrSuspendedOnly,
                recoveryAttempted: true
            ) == .fail
        )
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .noScreenSamples,
                recoveryAttempted: true
            ) == .fail
        )
    }

    @Test("Missing samples after restart can seed a synthetic cached startup frame")
    func missingSamplesAfterRestartCanSeedSyntheticStartupFrame() {
        #expect(shouldSeedSyntheticDesktopStartupFrame(
            readiness: .noScreenSamples,
            recoveryAttempted: true,
            hasCachedStartupFrame: false
        ))
        #expect(!shouldSeedSyntheticDesktopStartupFrame(
            readiness: .noScreenSamples,
            recoveryAttempted: false,
            hasCachedStartupFrame: false
        ))
        #expect(!shouldSeedSyntheticDesktopStartupFrame(
            readiness: .noScreenSamples,
            recoveryAttempted: true,
            hasCachedStartupFrame: true
        ))
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .noScreenSamples,
                recoveryAttempted: true,
                hasCachedStartupFrame: true
            ) == .proceed
        )
    }

    @Test("Blank or suspended samples do not request synthetic startup recovery")
    func blankOrSuspendedSamplesDoNotRequestSyntheticStartupRecovery() {
        #expect(!shouldSeedSyntheticDesktopStartupFrame(
            readiness: .blankOrSuspendedOnly,
            recoveryAttempted: true,
            hasCachedStartupFrame: false
        ))
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .blankOrSuspendedOnly,
                recoveryAttempted: true
            ) == .fail
        )
    }

    @Test("Only cached startup frame can satisfy missing startup samples")
    func cachedStartupFrameCanSatisfyMissingStartupSamples() {
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .noScreenSamples,
                recoveryAttempted: false,
                hasCachedStartupFrame: true
            ) == .proceed
        )
        #expect(
            desktopStartupCaptureRecoveryDecision(
                readiness: .noScreenSamples,
                recoveryAttempted: false
            ) == .restartCapture
        )
    }

    @Test("Cached startup frame injects only when no newer frame is queued")
    func cachedStartupFrameOnlyInjectsWhenQueueIsEmpty() {
        #expect(
            startupFrameReleaseDisposition(
                hasCachedFrame: true,
                hasQueuedFrame: false
            ) == .injectCachedFrame
        )
        #expect(
            startupFrameReleaseDisposition(
                hasCachedFrame: false,
                hasQueuedFrame: false
            ) == .none
        )
        #expect(
            startupFrameReleaseDisposition(
                hasCachedFrame: true,
                hasQueuedFrame: true
            ) == .none
        )
    }

    @Test("Injected startup frame clears idle classification")
    func injectedStartupFrameClearsIdleClassification() {
        let info = CapturedFrameInfo(
            contentRect: .zero,
            dirtyPercentage: 0,
            isIdleFrame: true
        )

        let resolved = resolvedStartupFrameInjectionInfo(info)
        #expect(resolved.isIdleFrame == false)
        #expect(resolved.contentRect == info.contentRect)
        #expect(resolved.dirtyPercentage == info.dirtyPercentage)
    }
}
#endif
