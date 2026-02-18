//
//  DesktopResizeTransactionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop resize transaction policy decisions.
//

@testable import MirageKitHost
import MirageKit
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Resize Transaction Policy")
struct DesktopResizeTransactionPolicyTests {
    @Test("Resize no-op decision skips exact resolution and refresh")
    func resizeNoOpDecisionSkipsExactMatch() {
        let decision = desktopResizeNoOpDecision(
            currentResolution: CGSize(width: 6016, height: 3384),
            currentRefreshRate: 120,
            requestedResolution: CGSize(width: 6016, height: 3384),
            requestedRefreshRate: 120
        )

        #expect(decision == .noOp)
    }

    @Test("Resize no-op decision applies on mismatch")
    func resizeNoOpDecisionAppliesOnMismatch() {
        let decision = desktopResizeNoOpDecision(
            currentResolution: CGSize(width: 6016, height: 3384),
            currentRefreshRate: 120,
            requestedResolution: CGSize(width: 5120, height: 2880),
            requestedRefreshRate: 60
        )

        #expect(decision == .apply)
    }

    @Test("Mirrored mode uses suspend and restore plan")
    func mirroredModeUsesSuspendAndRestore() {
        let plan = desktopResizeMirroringPlan(for: .mirrored)
        #expect(plan == .suspendAndRestore)
    }

    @Test("Secondary mode keeps mirroring unchanged")
    func secondaryModeKeepsMirroringUnchanged() {
        let plan = desktopResizeMirroringPlan(for: .secondary)
        #expect(plan == .unchanged)
    }

    @Test("Generation-change rebind is suppressed during resize transaction")
    func generationRebindSuppressedDuringResize() {
        let decision = desktopGenerationChangeRebindDecision(
            previousGeneration: 10,
            newGeneration: 11,
            desktopResizeInFlight: true
        )

        #expect(decision == .skipResizeInFlight)
    }

    @Test("Generation-change rebind runs when resize is idle")
    func generationRebindRunsWhenResizeIsIdle() {
        let decision = desktopGenerationChangeRebindDecision(
            previousGeneration: 10,
            newGeneration: 11,
            desktopResizeInFlight: false
        )

        #expect(decision == .rebind)
    }
}
#endif
