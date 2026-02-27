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

    @Test("Resize no-op decision applies on tiny pixel drift for pixel-perfect sizing")
    func resizeNoOpDecisionAppliesOnTinyPixelDrift() {
        let decision = desktopResizeNoOpDecision(
            currentResolution: CGSize(width: 2474, height: 1752),
            currentRefreshRate: 60,
            requestedResolution: CGSize(width: 2474, height: 1764),
            requestedRefreshRate: 60
        )

        #expect(decision == .apply)
    }

    @Test("Resize no-op decision still applies on refresh mismatch")
    func resizeNoOpDecisionAppliesOnRefreshMismatch() {
        let decision = desktopResizeNoOpDecision(
            currentResolution: CGSize(width: 2474, height: 1752),
            currentRefreshRate: 60,
            requestedResolution: CGSize(width: 2474, height: 1752),
            requestedRefreshRate: 120
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

    @Test("Window resize no-op skips exact visible resolution")
    func windowResizeNoOpSkipsExactMatch() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 2560, height: 1440),
            currentDisplayResolution: nil,
            requestedVisibleResolution: CGSize(width: 2560, height: 1440)
        )

        #expect(decision == .noOp)
    }

    @Test("Window resize no-op applies on visible resolution mismatch")
    func windowResizeNoOpAppliesOnMismatch() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 2560, height: 1440),
            currentDisplayResolution: nil,
            requestedVisibleResolution: CGSize(width: 3008, height: 1692)
        )

        #expect(decision == .apply)
    }

    @Test("Window resize no-op tolerates tiny visible-resolution drift")
    func windowResizeNoOpToleratesTinyDrift() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 2560, height: 1440),
            currentDisplayResolution: nil,
            requestedVisibleResolution: CGSize(width: 2561, height: 1442)
        )

        #expect(decision == .noOp)
    }

    @Test("Window resize no-op skips when requested size matches calibrated display size")
    func windowResizeNoOpSkipsDisplayMatch() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 6016, height: 3324),
            currentDisplayResolution: CGSize(width: 6016, height: 3384),
            requestedVisibleResolution: CGSize(width: 6016, height: 3384)
        )

        #expect(decision == .noOp)
    }

    @Test("Display separation anchor prefers physical original main display")
    func displaySeparationAnchorPrefersPhysicalOriginalMain() {
        let display1: CGDirectDisplayID = 1
        let display23: CGDirectDisplayID = 23
        let display24: CGDirectDisplayID = 24

        let anchor = displaySeparationAnchorDisplayID(
            displays: [display1, display23, display24],
            virtualDisplayID: display24,
            originalMainDisplayID: display1,
            isVirtualDisplay: { $0 == display23 || $0 == display24 },
            displayBounds: { displayID in
                switch displayID {
                case display1:
                    return CGRect(x: 0, y: 0, width: 2056, height: 1329)
                case display23:
                    return CGRect(x: 2056, y: 0, width: 1375, height: 1031)
                default:
                    return .zero
                }
            }
        )

        #expect(anchor == display1)
    }

    @Test("Display separation anchor picks rightmost physical display when main is unavailable")
    func displaySeparationAnchorPicksRightmostPhysical() {
        let display2: CGDirectDisplayID = 2
        let display3: CGDirectDisplayID = 3
        let display24: CGDirectDisplayID = 24

        let anchor = displaySeparationAnchorDisplayID(
            displays: [display2, display3, display24],
            virtualDisplayID: display24,
            originalMainDisplayID: 1,
            isVirtualDisplay: { $0 == display24 },
            displayBounds: { displayID in
                switch displayID {
                case display2:
                    return CGRect(x: 0, y: 0, width: 1920, height: 1080)
                case display3:
                    return CGRect(x: 1920, y: 0, width: 2560, height: 1440)
                default:
                    return .zero
                }
            }
        )

        #expect(anchor == display3)
    }

    @Test("Display separation anchor falls back to rightmost candidate when only virtual displays remain")
    func displaySeparationAnchorFallsBackToVirtualCandidate() {
        let display23: CGDirectDisplayID = 23
        let display24: CGDirectDisplayID = 24
        let display25: CGDirectDisplayID = 25

        let anchor = displaySeparationAnchorDisplayID(
            displays: [display23, display24, display25],
            virtualDisplayID: display25,
            originalMainDisplayID: 1,
            isVirtualDisplay: { _ in true },
            displayBounds: { displayID in
                switch displayID {
                case display23:
                    return CGRect(x: 100, y: 0, width: 1000, height: 700)
                case display24:
                    return CGRect(x: 1200, y: 0, width: 1000, height: 700)
                default:
                    return .zero
                }
            }
        )

        #expect(anchor == display24)
    }
}
#endif
