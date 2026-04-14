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
            bundleIdentifier: "com.example.app",
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
            bundleIdentifier: "com.example.app",
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

    @Test("Window-added callback payload uses resolved stream window ID")
    func windowAddedCallbackUsesResolvedWindowID() {
        let candidateWindowID = WindowID(111)
        let resolvedWindow = makeWindow(
            id: 222,
            title: "Resolved",
            origin: CGPoint(x: 60, y: 80),
            size: CGSize(width: 1440, height: 900)
        )
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Client",
            deviceType: .mac,
            connectedAt: Date()
        )
        let streamSession = MirageStreamSession(
            id: 7,
            window: resolvedWindow,
            client: client
        )

        let event = MirageHostService.resolvedWindowAddedEvent(from: streamSession)

        #expect(event.windowID == resolvedWindow.id)
        #expect(event.windowID != candidateWindowID)
        #expect(event.width == 1440)
        #expect(event.height == 900)
    }

    @Test("Restore owner validation blocks stale teardown from another stream")
    func restoreOwnerValidationBlocksStaleTeardown() {
        let expectedOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 2,
            windowID: 301,
            displayID: 10,
            generation: 4
        )
        let activeOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 9,
            windowID: 301,
            displayID: 11,
            generation: 8
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

    @Test("Stale owner recovery decision selects reclaim for inactive owner stream")
    func staleOwnerRecoveryDecisionSelectsReclaimForInactiveOwnerStream() {
        let staleOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 9,
            windowID: 301,
            displayID: 10,
            generation: 4
        )
        let decision = WindowSpaceManager.staleOwnerRecoveryDecision(
            savedOwner: staleOwner,
            activeStreamIDs: [1, 2, 3]
        )
        #expect(decision == .recover(streamID: staleOwner.streamID))
    }

    @Test("Stale owner recovery decision rejects active owner conflict")
    func staleOwnerRecoveryDecisionRejectsActiveOwnerConflict() {
        let activeOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 9,
            windowID: 301,
            displayID: 10,
            generation: 4
        )
        let decision = WindowSpaceManager.staleOwnerRecoveryDecision(
            savedOwner: activeOwner,
            activeStreamIDs: [8, 9]
        )
        #expect(decision == .activeOwnerConflict(streamID: activeOwner.streamID))
    }

    @Test("Active owner claims are filtered from app-window remap candidates")
    func activeOwnerClaimsAreFilteredFromAppWindowRemapCandidates() {
        let activeClaimWindowID = WindowID(7001)
        let inactiveClaimWindowID = WindowID(7002)
        let activeOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 44,
            windowID: activeClaimWindowID,
            displayID: 1,
            generation: 2
        )
        let inactiveOwner = WindowSpaceManager.WindowBindingOwner(
            streamID: 55,
            windowID: inactiveClaimWindowID,
            displayID: 1,
            generation: 2
        )
        let savedStates: [WindowID: WindowSpaceManager.SavedWindowState] = [
            activeClaimWindowID: WindowSpaceManager.SavedWindowState(
                windowID: activeClaimWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                trafficLightVisibilitySnapshot: nil,
                owner: activeOwner,
                savedAt: Date()
            ),
            inactiveClaimWindowID: WindowSpaceManager.SavedWindowState(
                windowID: inactiveClaimWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                trafficLightVisibilitySnapshot: nil,
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
                trafficLightVisibilitySnapshot: nil,
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: stoppedStreamID,
                    windowID: firstOwnedWindowID,
                    displayID: 1,
                    generation: 1
                ),
                savedAt: Date()
            ),
            secondOwnedWindowID: WindowSpaceManager.SavedWindowState(
                windowID: secondOwnedWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                trafficLightVisibilitySnapshot: nil,
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: stoppedStreamID,
                    windowID: secondOwnedWindowID,
                    displayID: 1,
                    generation: 2
                ),
                savedAt: Date()
            ),
            otherStreamWindowID: WindowSpaceManager.SavedWindowState(
                windowID: otherStreamWindowID,
                originalFrame: .zero,
                originalSpaceIDs: [],
                trafficLightVisibilitySnapshot: nil,
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: otherStreamID,
                    windowID: otherStreamWindowID,
                    displayID: 1,
                    generation: 1
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
        #expect(MirageHostService.initialAppWindowStartupDecision(startedWindowCount: 1) == .continueStreaming)
        #expect(MirageHostService.initialAppWindowStartupDecision(startedWindowCount: 0) == .abortSession)

        let manager = AppStreamManager()
        let disposition = await manager.noteWindowStartupFailed(
            bundleID: "com.example.app",
            windowID: 404,
            retryable: true,
            reason: "window already bound"
        )

        guard case let .retryScheduled(attempt, _) = disposition else {
            Issue.record("Expected retry scheduling for retryable startup miss")
            return
        }
        #expect(attempt == 1)
    }

    @Test("Startup batching caps each wave to bounded concurrency")
    func startupBatchingCapsConcurrencyPerWave() {
        let ranges = MirageHostService.appWindowStartupBatchRanges(
            totalCount: 7,
            maxConcurrentWindowStarts: 2
        )

        #expect(ranges == [0 ..< 2, 2 ..< 4, 4 ..< 6, 6 ..< 7])
        #expect(ranges.allSatisfy { $0.count <= 2 })
    }

    @Test("Initial startup discovery uses bounded retry backoff")
    func initialStartupDiscoveryUsesBoundedRetryBackoff() {
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 1) == .milliseconds(250))
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 2) == .milliseconds(350))
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 3) == .milliseconds(500))
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 4) == .milliseconds(750))
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 5) == .seconds(1))
        #expect(MirageHostService.initialAppWindowDiscoveryRetryDelay(afterAttempt: 30) == .seconds(1))
    }

    @Test("Initial startup requests new app windows on an extended bounded schedule")
    func initialStartupRequestsNewWindowOnExtendedBoundedSchedule() {
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 1,
                newWindowRequestAttempts: 0
            ) == false
        )
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 2,
                newWindowRequestAttempts: 0
            ) == true
        )
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 4,
                newWindowRequestAttempts: 1
            ) == false
        )
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 5,
                newWindowRequestAttempts: 1
            ) == true
        )
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 11,
                newWindowRequestAttempts: 3
            ) == true
        )
        #expect(
            MirageHostService.shouldRequestNewAppWindowOnInitialDiscovery(
                discoveryAttempt: 14,
                newWindowRequestAttempts: 4
            ) == false
        )
    }

    @Test("Existing-session select decision enforces owner, state, and slot cap")
    func existingSessionSelectDecisionEnforcesOwnerStateAndCap() {
        let ownerClientID = UUID()
        let requesterClientID = UUID()

        #expect(
            MirageHostService.existingSessionSelectDecision(
                sessionClientID: ownerClientID,
                requestClientID: ownerClientID,
                sessionState: .streaming,
                hasVisibleSlotCapacity: true
            ) == .allowExpansion
        )
        #expect(
            MirageHostService.existingSessionSelectDecision(
                sessionClientID: ownerClientID,
                requestClientID: requesterClientID,
                sessionState: .streaming,
                hasVisibleSlotCapacity: true
            ) == .rejectOtherClientOwner
        )
        #expect(
            MirageHostService.existingSessionSelectDecision(
                sessionClientID: ownerClientID,
                requestClientID: ownerClientID,
                sessionState: .starting,
                hasVisibleSlotCapacity: true
            ) == .rejectSessionNotStreaming
        )
        #expect(
            MirageHostService.existingSessionSelectDecision(
                sessionClientID: ownerClientID,
                requestClientID: ownerClientID,
                sessionState: .streaming,
                hasVisibleSlotCapacity: false
            ) == .rejectVisibleSlotCapReached
        )
    }

    @Test("Window-close cooldown ignores duplicate close notifications")
    func windowCloseCooldownIgnoresDuplicateCloseNotifications() {
        #expect(
            MirageHostService.windowCloseCooldownDecision(
                existingPendingClosedWindowID: 42,
                closingWindowID: 42
            ) == .ignoreDuplicate
        )
        #expect(
            MirageHostService.windowCloseCooldownDecision(
                existingPendingClosedWindowID: 41,
                closingWindowID: 42
            ) == .enterCooldown
        )
        #expect(
            MirageHostService.windowCloseCooldownDecision(
                existingPendingClosedWindowID: nil,
                closingWindowID: 42
            ) == .enterCooldown
        )
    }

    @Test("Placement repair skips windows already in replacement cooldown")
    func placementRepairSkipsWindowsInReplacementCooldown() {
        let closedWindowID = WindowID(42)
        let unrelatedWindowID = WindowID(99)

        #expect(
            MirageHostService.shouldSkipPlacementRepair(
                windowID: closedWindowID,
                pendingReplacementClosedWindowIDs: [closedWindowID]
            )
        )
        #expect(
            !MirageHostService.shouldSkipPlacementRepair(
                windowID: unrelatedWindowID,
                pendingReplacementClosedWindowIDs: [closedWindowID]
            )
        )
    }

    @Test("Preferred app-window ordering prioritizes focused then main windows")
    func preferredWindowOrderingPrioritizesFocusedThenMain() {
        let focusedCandidate = AppStreamWindowCandidate(
            bundleIdentifier: "com.example.app",
            window: makeWindow(id: 801, title: "Focused", origin: .zero),
            classification: .primary,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil,
            isFocused: true,
            isMain: false
        )
        let mainCandidate = AppStreamWindowCandidate(
            bundleIdentifier: "com.example.app",
            window: makeWindow(id: 802, title: "Main", origin: .zero),
            classification: .primary,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil,
            isFocused: false,
            isMain: true
        )
        let fallbackCandidate = AppStreamWindowCandidate(
            bundleIdentifier: "com.example.app",
            window: makeWindow(id: 803, title: "Fallback", origin: .zero),
            classification: .primary,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil,
            isFocused: false,
            isMain: false
        )

        let sorted = [fallbackCandidate, mainCandidate, focusedCandidate]
            .sorted(by: AppStreamWindowCatalog.preferredOrder(lhs:rhs:))
        #expect(sorted.map(\.window.id) == [801, 802, 803])
    }

    @MainActor
    @Test("Active stream maps remain consistent across register/update/remove")
    func activeStreamMapsRemainConsistent() async {
        let host = MirageHostService(hostName: "MapConsistencyHost")
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Client",
            deviceType: .mac,
            connectedAt: Date()
        )

        let initialWindow = makeWindow(id: 7001, title: "Initial", origin: CGPoint(x: 20, y: 20))
        host.registerActiveStreamSession(
            MirageStreamSession(id: 55, window: initialWindow, client: client)
        )

        #expect(host.activeSessionByStreamID[55]?.window.id == 7001)
        #expect(host.activeStreamIDByWindowID[7001] == 55)
        #expect(host.activeWindowIDByStreamID[55] == 7001)

        let remappedWindow = makeWindow(id: 7002, title: "Remapped", origin: CGPoint(x: 30, y: 30))
        host.registerActiveStreamSession(
            MirageStreamSession(id: 55, window: remappedWindow, client: client)
        )

        #expect(host.activeSessionByStreamID[55]?.window.id == 7002)
        #expect(host.activeStreamIDByWindowID[7001] == nil)
        #expect(host.activeStreamIDByWindowID[7002] == 55)
        #expect(host.activeWindowIDByStreamID[55] == 7002)

        host.removeActiveStreamSession(streamID: 55)

        #expect(host.activeSessionByStreamID[55] == nil)
        #expect(host.activeStreamIDByWindowID[7002] == nil)
        #expect(host.activeWindowIDByStreamID[55] == nil)
    }

    @MainActor
    @Test("New primary window stays hidden when an existing streamed window is healthy")
    func newPrimaryWindowStaysHiddenWhenExistingStreamedWindowIsHealthy() async {
        let host = MirageHostService(hostName: "LifecycleHost")
        let clientID = UUID()
        let bundleID = "com.example.app"
        let streamedWindowID = WindowID(9131)
        let newWindowID = WindowID(9132)

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleID,
            appName: "Example App",
            appPath: "/Applications/Example.app",
            clientID: clientID,
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1280, height: 720),
            requestedClientScaleFactor: nil,
            maxVisibleSlots: 1,
            bitrateBudgetBps: nil
        )
        await host.appStreamManager.markSessionStreaming(bundleID)
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleID,
            windowID: streamedWindowID,
            streamID: 77,
            title: "Current Project",
            width: 1280,
            height: 720,
            isResizable: true,
            slotIndex: 0
        )

        let newCandidate = makeCandidate(
            windowID: newWindowID,
            title: "Second Project",
            origin: CGPoint(x: 120, y: 120)
        )
        await host.handleNewWindowFromStreamedApp(bundleID: bundleID, candidate: newCandidate)

        let session = await host.appStreamManager.getSession(bundleIdentifier: bundleID)
        let visibleWindowIDs = session.map { Array($0.windowStreams.keys).sorted(by: <) } ?? []
        #expect(visibleWindowIDs == [streamedWindowID])
        #expect(session?.hiddenWindows[newWindowID] != nil)
    }

    private func makeCandidate(
        windowID: WindowID,
        title: String,
        origin: CGPoint,
        size: CGSize = CGSize(width: 960, height: 720),
        pid: Int32 = 4242,
        bundleID: String = "com.example.app"
    ) -> AppStreamWindowCandidate {
        AppStreamWindowCandidate(
            bundleIdentifier: bundleID,
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

    private func makeWindow(
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
