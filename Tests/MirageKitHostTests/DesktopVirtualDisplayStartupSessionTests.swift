//
//  DesktopVirtualDisplayStartupSessionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Virtual Display Startup Session", .serialized)
struct DesktopVirtualDisplayStartupSessionTests {
    private func makePlan() -> DesktopVirtualDisplayStartupPlan {
        desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )
    }

    @Test("Activation failures advance into descriptor fallback")
    func activationFailuresAdvanceIntoDescriptorFallback() {
        let plan = makePlan()
        var session = DesktopVirtualDisplayStartupSession(plan: plan)

        let failureClass = session.recordFailure(
            SharedVirtualDisplayManager.SharedDisplayError.creationFailed("mode activation failed")
        )

        let nextIndex = session.nextRetryIndex(
            after: failureClass,
            attempts: plan.attempts,
            currentIndex: 0
        )

        #expect(failureClass == .activation)
        #expect(nextIndex == 1)
        #expect(plan.attempts[nextIndex ?? 0].fallbackKind == .descriptorFallback)
    }

    @Test("Space failures skip descriptor fallback and go straight to conservative retry")
    func spaceFailuresSkipDescriptorFallback() {
        let plan = makePlan()
        var session = DesktopVirtualDisplayStartupSession(plan: plan)

        let failureClass = session.recordFailure(
            SharedVirtualDisplayManager.SharedDisplayError.spaceNotFound(123)
        )

        let nextIndex = session.nextRetryIndex(
            after: failureClass,
            attempts: plan.attempts,
            currentIndex: 0
        )

        #expect(failureClass == .spaceAssignment)
        #expect(nextIndex == 2)
        #expect(plan.attempts[nextIndex ?? 0].fallbackKind == .conservative)
    }

    @Test("Non-retryable failures abort the ladder")
    func nonRetryableFailuresAbortTheLadder() {
        let plan = makePlan()
        var session = DesktopVirtualDisplayStartupSession(plan: plan)

        let failureClass = session.recordFailure(
            SharedVirtualDisplayManager.SharedDisplayError.apiNotAvailable
        )

        let nextIndex = session.nextRetryIndex(
            after: failureClass,
            attempts: plan.attempts,
            currentIndex: 0
        )

        #expect(failureClass == .nonRetryable)
        #expect(nextIndex == nil)
    }
}
#endif
