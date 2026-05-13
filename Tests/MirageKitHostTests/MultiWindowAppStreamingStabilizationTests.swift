//
//  MultiWindowAppStreamingStabilizationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Multi-window app streaming stabilization and scaling regression coverage.
//

@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Multi-Window App Streaming Stabilization")
struct MultiWindowAppStreamingStabilizationTests {
    @Test("Binding planner enforces unique remaps for stale IDs")
    func bindingPlannerEnforcesUniqueRemaps() {
        let candidateA = makeCandidate(
            windowID: 9001,
            title: "Document",
            origin: CGPoint(x: 100, y: 120)
        )
        let candidateB = makeCandidate(
            windowID: 9002,
            title: "Document",
            origin: CGPoint(x: 120, y: 140)
        )

        let liveA = makeWindow(
            id: 2001,
            title: "Document",
            origin: CGPoint(x: 100, y: 120)
        )
        let liveB = makeWindow(
            id: 2002,
            title: "Document",
            origin: CGPoint(x: 120, y: 140)
        )

        let plan = AppWindowBindingPlanner.plan(
            candidates: [candidateA, candidateB],
            liveWindows: [liveA, liveB],
            claimedWindowIDs: []
        )

        #expect(plan.unresolvedCandidates.isEmpty)
        #expect(plan.resolvedBindings.count == 2)
        let resolvedWindowIDs = Set(plan.resolvedBindings.map(\ .resolvedWindow.id))
        #expect(resolvedWindowIDs.count == 2)
    }

    @Test("Binding planner rejects claimed remap targets")
    func bindingPlannerRejectsClaimedRemapTargets() {
        let candidate = makeCandidate(
            windowID: 9003,
            title: "Inspector",
            origin: CGPoint(x: 200, y: 160)
        )
        let claimedLive = makeWindow(
            id: 2100,
            title: "Inspector",
            origin: CGPoint(x: 200, y: 160)
        )

        let plan = AppWindowBindingPlanner.plan(
            candidates: [candidate],
            liveWindows: [claimedLive],
            claimedWindowIDs: [claimedLive.id]
        )

        #expect(plan.resolvedBindings.isEmpty)
        #expect(plan.unresolvedCandidates.map(\ .window.id) == [candidate.window.id])
    }

    @Test("Initial startup handoff rebinds from stale launcher to replacement primary window")
    func initialStartupHandoffRebindsFromStaleLauncherToReplacementPrimaryWindow() {
        let launcherCandidate = makeCandidate(
            windowID: 9101,
            title: "Welcome",
            origin: CGPoint(x: 40, y: 40)
        )
        let projectCandidate = makeCandidate(
            windowID: 9102,
            title: "Project",
            origin: CGPoint(x: 80, y: 80)
        )
        let liveProjectWindow = makeWindow(
            id: projectCandidate.window.id,
            title: "Project",
            origin: CGPoint(x: 80, y: 80)
        )

        let binding = MirageHostService.resolveInitialAppWindowStartupBinding(
            candidates: [launcherCandidate, projectCandidate],
            liveWindows: [liveProjectWindow],
            visibleWindowIDs: [],
            claimedWindowIDs: [],
            preferredWindowID: launcherCandidate.window.id,
            deprioritizedWindowIDs: [launcherCandidate.window.id],
            excludedWindowIDs: []
        )

        #expect(binding?.candidate.window.id == projectCandidate.window.id)
        #expect(binding?.resolvedWindow.id == liveProjectWindow.id)
    }

    @Test("Initial startup handoff keeps the healthy preferred primary window")
    func initialStartupHandoffKeepsHealthyPreferredPrimaryWindow() {
        let launcherCandidate = makeCandidate(
            windowID: 9111,
            title: "Welcome",
            origin: CGPoint(x: 40, y: 40)
        )
        let projectCandidate = makeCandidate(
            windowID: 9112,
            title: "Project",
            origin: CGPoint(x: 80, y: 80)
        )
        let liveLauncherWindow = makeWindow(
            id: launcherCandidate.window.id,
            title: "Welcome",
            origin: CGPoint(x: 40, y: 40)
        )
        let liveProjectWindow = makeWindow(
            id: projectCandidate.window.id,
            title: "Project",
            origin: CGPoint(x: 80, y: 80)
        )

        let binding = MirageHostService.resolveInitialAppWindowStartupBinding(
            candidates: [launcherCandidate, projectCandidate],
            liveWindows: [liveLauncherWindow, liveProjectWindow],
            visibleWindowIDs: [],
            claimedWindowIDs: [],
            preferredWindowID: launcherCandidate.window.id,
            deprioritizedWindowIDs: [],
            excludedWindowIDs: []
        )

        #expect(binding?.candidate.window.id == launcherCandidate.window.id)
        #expect(binding?.resolvedWindow.id == liveLauncherWindow.id)
    }

    @Test("Initial startup handoff keeps detached fallback windows eligible across refresh")
    func initialStartupHandoffKeepsDetachedFallbackWindowsEligibleAcrossRefresh() {
        let detachedFallbackCandidate = AppStreamWindowCandidate(
            window: makeWindow(
                id: 9113,
                title: "Inspector",
                origin: CGPoint(x: 70, y: 70)
            ),
            classification: .auxiliary,
            role: "AXFloatingWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil,
            isFocused: true,
            isMain: false
        )
        let liveInspectorWindow = makeWindow(
            id: detachedFallbackCandidate.window.id,
            title: "Inspector",
            origin: CGPoint(x: 70, y: 70)
        )

        let binding = MirageHostService.resolveInitialAppWindowStartupBinding(
            candidates: [detachedFallbackCandidate],
            liveWindows: [liveInspectorWindow],
            visibleWindowIDs: [],
            claimedWindowIDs: [],
            preferredWindowID: detachedFallbackCandidate.window.id,
            deprioritizedWindowIDs: [],
            excludedWindowIDs: []
        )

        #expect(binding?.candidate.window.id == detachedFallbackCandidate.window.id)
        #expect(binding?.resolvedWindow.id == liveInspectorWindow.id)
    }

    @Test("Initial startup handoff rejects auxiliary and claimed window candidates")
    func initialStartupHandoffRejectsAuxiliaryAndClaimedWindowCandidates() {
        let auxiliaryCandidate = AppStreamWindowCandidate(
            window: makeWindow(
                id: 9121,
                title: "Inspector",
                origin: CGPoint(x: 20, y: 20)
            ),
            classification: .auxiliary,
            role: "AXSheet",
            subrole: "AXSystemDialog",
            parentWindowID: 9000
        )
        let claimedCandidate = makeCandidate(
            windowID: 9122,
            title: "Claimed",
            origin: CGPoint(x: 60, y: 60)
        )
        let eligibleCandidate = makeCandidate(
            windowID: 9123,
            title: "Eligible",
            origin: CGPoint(x: 100, y: 100)
        )

        let binding = MirageHostService.resolveInitialAppWindowStartupBinding(
            candidates: [auxiliaryCandidate, claimedCandidate, eligibleCandidate],
            liveWindows: [
                auxiliaryCandidate.window,
                claimedCandidate.window,
                eligibleCandidate.window,
            ],
            visibleWindowIDs: [],
            claimedWindowIDs: [claimedCandidate.window.id],
            preferredWindowID: nil,
            deprioritizedWindowIDs: [],
            excludedWindowIDs: []
        )

        #expect(binding?.candidate.window.id == eligibleCandidate.window.id)
        #expect(binding?.resolvedWindow.id == eligibleCandidate.window.id)
    }

    @Test("Restore owner validation blocks stale teardown from another stream")
    func restoreOwnerValidationBlocksStaleTeardown() {
        let expectedOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 2
        )
        let activeOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 9
        )

        let mismatchResult = WindowSpaceManager.validateRestoreOwner(
            expectedOwner: expectedOwner,
            savedOwner: activeOwner
        )
        #expect(
            mismatchResult == .ownerMismatch(expectedStreamID: expectedOwner.streamID, actualStreamID: activeOwner.streamID)
        )

        let missingOwnerResult = WindowSpaceManager.validateRestoreOwner(
            expectedOwner: expectedOwner,
            savedOwner: nil
        )
        #expect(
            missingOwnerResult == .ownerMismatch(expectedStreamID: expectedOwner.streamID, actualStreamID: 0)
        )
    }

    @Test("Active owner claims are filtered from app-window remap candidates")
    func activeOwnerClaimsAreFilteredFromAppWindowRemapCandidates() {
        let activeClaimWindowID = WindowID(7001)
        let inactiveClaimWindowID = WindowID(7002)
        let activeOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 44
        )
        let inactiveOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 55
        )
        let savedStates: [WindowID: WindowSpaceManager.SavedWindowState] = [
            activeClaimWindowID: WindowSpaceManager.SavedWindowState(
                windowID: activeClaimWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                owner: activeOwner,
                savedAt: Date()
            ),
            inactiveClaimWindowID: WindowSpaceManager.SavedWindowState(
                windowID: inactiveClaimWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                owner: inactiveOwner,
                savedAt: Date()
            ),
        ]
        let activeClaims = WindowSpaceManager.claimedWindowIDsForActiveOwners(
            from: savedStates,
            activeStreamIDs: [activeOwner.streamID]
        )
        #expect(activeClaims == [activeClaimWindowID])

        let candidate = makeCandidate(
            windowID: 9004,
            title: "Inspector",
            origin: CGPoint(x: 240, y: 180)
        )
        let claimedLiveWindow = makeWindow(
            id: activeClaimWindowID,
            title: "Inspector",
            origin: CGPoint(x: 240, y: 180)
        )
        let plan = AppWindowBindingPlanner.plan(
            candidates: [candidate],
            liveWindows: [claimedLiveWindow],
            claimedWindowIDs: activeClaims
        )

        #expect(plan.resolvedBindings.isEmpty)
        #expect(plan.unresolvedCandidates.map(\.window.id) == [candidate.window.id])
    }

    @Test("Stopped-stream cleanup targets every saved window owned by that stream")
    func stoppedStreamCleanupTargetsEverySavedWindowOwnedByThatStream() {
        let firstOwnedWindowID = WindowID(7010)
        let secondOwnedWindowID = WindowID(7011)
        let otherStreamWindowID = WindowID(7012)
        let stoppedStreamID = StreamID(44)
        let otherStreamID = StreamID(55)
        let savedStates: [WindowID: WindowSpaceManager.SavedWindowState] = [
            firstOwnedWindowID: WindowSpaceManager.SavedWindowState(
                windowID: firstOwnedWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: stoppedStreamID
                ),
                savedAt: Date()
            ),
            secondOwnedWindowID: WindowSpaceManager.SavedWindowState(
                windowID: secondOwnedWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: stoppedStreamID
                ),
                savedAt: Date()
            ),
            otherStreamWindowID: WindowSpaceManager.SavedWindowState(
                windowID: otherStreamWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: otherStreamID
                ),
                savedAt: Date()
            ),
        ]

        let ownedWindowIDs = WindowSpaceManager.windowIDsOwned(
            by: stoppedStreamID,
            from: savedStates
        )

        #expect(ownedWindowIDs == [firstOwnedWindowID, secondOwnedWindowID])
    }

    @Test("Partial startup policy keeps session alive and failed windows retry")
    func partialStartupPolicyKeepsSessionAndRetriesFailures() async {
        let manager = AppStreamManager()
        let disposition = await manager.noteWindowStartupFailed(
            bundleID: "com.example.app",
            windowID: 404,
            retryable: true
        )

        guard case let .retryScheduled(attempt, _) = disposition else {
            Issue.record("Expected retry scheduling for retryable startup miss")
            return
        }
        #expect(attempt == 1)
    }

    @Test("Lifecycle startup eligibility rejects parented and claimed candidates")
    func lifecycleStartupEligibilityRejectsParentedAndClaimedCandidates() {
        let parentedAuxiliary = AppStreamWindowCandidate(
            window: makeWindow(id: 9131, title: "Sheet", origin: CGPoint(x: 20, y: 20)),
            classification: .auxiliary,
            role: "AXSheet",
            subrole: "AXDialog",
            parentWindowID: 9129,
            isFocused: true,
            isMain: true
        )
        let claimedPrimary = makeCandidate(
            windowID: 9132,
            title: "Claimed",
            origin: CGPoint(x: 40, y: 40)
        )
        let detachedAuxiliary = AppStreamWindowCandidate(
            window: makeWindow(id: 9133, title: "Detached Inspector", origin: CGPoint(x: 60, y: 60)),
            classification: .auxiliary,
            role: "AXWindow",
            subrole: "AXFloatingWindow",
            parentWindowID: nil,
            isFocused: true,
            isMain: false
        )

        let eligible = MirageHostService.lifecycleStartupEligibleCandidates(
            from: [parentedAuxiliary, claimedPrimary, detachedAuxiliary],
            visibleWindowIDs: [],
            claimedWindowIDs: [claimedPrimary.window.id]
        )

        #expect(eligible.map(\.window.id) == [detachedAuxiliary.window.id])
    }

    func makeCandidate(
        windowID: WindowID,
        title: String,
        origin: CGPoint,
        size: CGSize = CGSize(width: 960, height: 720),
        pid: Int32 = 4242,
        bundleID: String = "com.example.app"
    ) -> AppStreamWindowCandidate {
        AppStreamWindowCandidate(
            window: makeWindow(
                id: windowID,
                title: title,
                origin: origin,
                size: size,
                pid: pid,
                bundleID: bundleID
            ),
            classification: .primary,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil
        )
    }

    func makeWindow(
        id: WindowID,
        title: String,
        origin: CGPoint,
        size: CGSize = CGSize(width: 960, height: 720),
        pid: Int32 = 4242,
        bundleID: String = "com.example.app"
    ) -> MirageWindow {
        MirageWindow(
            id: id,
            title: title,
            application: MirageApplication(
                id: pid,
                bundleIdentifier: bundleID,
                name: "Example App"
            ),
            frame: CGRect(origin: origin, size: size),
            isOnScreen: true,
            windowLayer: 0
        )
    }
}
#endif
