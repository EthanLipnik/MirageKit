//
//  DesktopResizeTransactionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop resize transaction policy decisions.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import CoreGraphics
import Testing

@Suite("Desktop Resize Transaction Policy")
struct DesktopResizeTransactionPolicyTests {

    @Test("Unified resize requires mirroring restore success")
    func unifiedResizeRequiresMirroringRestoreSuccess() {
        #expect(desktopResizeRequiresMirroringRestoreSuccess(desktopStreamMode: .unified))
        #expect(!desktopResizeRequiresMirroringRestoreSuccess(desktopStreamMode: .secondary))
    }

    @Test("Mirrored mode suspends mirroring for in-place updates and recreation")
    func mirroredModeSuspendsMirroringForInPlaceUpdatesAndRecreation() {
        #expect(
            desktopResizeShouldSuspendMirroring(
                plan: .suspendAndRestore,
                updateOutcome: .updatedInPlace
            )
        )
        #expect(
            !desktopResizeShouldSuspendMirroring(
                plan: .suspendAndRestore,
                updateOutcome: .noChange
            )
        )
        #expect(
            desktopResizeShouldSuspendMirroring(
                plan: .suspendAndRestore,
                updateOutcome: .requiresRecreation
            )
        )
    }

    @Test("Residual mirroring is only cleared for same-generation secondary resizes when recreation occurred")
    func residualMirroringIsOnlyClearedWhenGenerationChanges() {
        #expect(
            !desktopResizeShouldDisableResidualMirroring(
                plan: .unchanged,
                generationChanged: false,
                hasResidualMirroringState: true
            )
        )
        #expect(
            desktopResizeShouldDisableResidualMirroring(
                plan: .unchanged,
                generationChanged: true,
                hasResidualMirroringState: true
            )
        )
        #expect(
            !desktopResizeShouldDisableResidualMirroring(
                plan: .unchanged,
                generationChanged: true,
                hasResidualMirroringState: false
            )
        )
    }

    @Test("Missing shared display requires recreation when updates cannot recreate immediately")
    func missingSharedDisplayRequiresExplicitRecreationWhenDisallowed() {
        #expect(sharedDisplayMissingUpdateDecision(allowRecreation: false) == .requiresRecreation)
    }

    @Test("Missing shared display recovers immediately when recreation is allowed")
    func missingSharedDisplayRecoversImmediatelyWhenAllowed() {
        #expect(sharedDisplayMissingUpdateDecision(allowRecreation: true) == .recreateNow)
    }

    @Test("Desktop resize recreation retries when old Mirage display is still tearing down")
    func desktopResizeRecreationRetriesForTransientResidualDisplay() {
        let residualDisplayID: CGDirectDisplayID = 32
        let error = SharedVirtualDisplayManager.SharedDisplayError.residualMirageDisplaysOnline([residualDisplayID])

        #expect(
            desktopResizeRecreateFailureDecision(error: error) ==
                .retryAfterResidualDisplayClears([residualDisplayID])
        )
    }

    @Test("Desktop resize recreation does not retry unrelated display errors")
    func desktopResizeRecreationDoesNotRetryUnrelatedErrors() {
        let error = SharedVirtualDisplayManager.SharedDisplayError.creationFailed("mode activation failed")

        #expect(desktopResizeRecreateFailureDecision(error: error) == .fail)
    }

    @Test("Resize transaction aborts when desktop stream is already inactive")
    func resizeTransactionAbortsWhenStreamIsInactive() {
        let decision = desktopResizeTransactionContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: nil,
            hasDesktopContext: false
        )

        #expect(decision == .abortStreamInactive)
    }

    @Test("Resize transaction aborts when stream dies mid-transaction")
    func resizeTransactionAbortsWhenContextDisappears() {
        let decision = desktopResizeTransactionContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: 41,
            hasDesktopContext: false
        )

        #expect(decision == .abortStreamInactive)
    }

    @Test("Resize transaction continues only for active stream with live context")
    func resizeTransactionContinuesForActiveLiveStream() {
        let decision = desktopResizeTransactionContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: 41,
            hasDesktopContext: true
        )

        #expect(decision == .continueTransaction)
    }

    @Test("Unified resize failure rolls back to last known good display")
    func unifiedResizeFailureRollsBackToLastKnownGoodDisplay() {
        let decision = desktopResizeFailureRecoveryPlan(
            hasPreResizeSnapshot: true
        )

        #expect(decision == .rollbackToLastKnownGood)
    }

    @Test("Unified resize failure without rollback snapshot stops stream")
    func unifiedResizeFailureWithoutRollbackSnapshotStopsStream() {
        let decision = desktopResizeFailureRecoveryPlan(
            hasPreResizeSnapshot: false
        )

        #expect(decision == .stopStream)
    }

    @Test("Secondary resize failure rolls back to last known good display")
    func secondaryResizeFailureRollsBackToLastKnownGoodDisplay() {
        let decision = desktopResizeFailureRecoveryPlan(
            hasPreResizeSnapshot: true
        )

        #expect(decision == .rollbackToLastKnownGood)
    }

    @Test("Client fit fallback keeps virtual display capture but disables client resizing")
    func clientFitFallbackKeepsVirtualDisplayCaptureButDisablesClientResizing() {
        #expect(
            desktopResizeUsesClientFitPresentation(
                captureSource: .virtualDisplay,
                clientFitFallbackActive: true
            )
        )
        #expect(
            !desktopResizeAllowsClientResize(
                captureSource: .virtualDisplay,
                clientFitFallbackActive: true
            )
        )
    }

    @Test("Successful virtual display resize keeps client resizing enabled")
    func successfulVirtualDisplayResizeKeepsClientResizingEnabled() {
        #expect(
            !desktopResizeUsesClientFitPresentation(
                captureSource: .virtualDisplay,
                clientFitFallbackActive: false
            )
        )
        #expect(
            desktopResizeAllowsClientResize(
                captureSource: .virtualDisplay,
                clientFitFallbackActive: false
            )
        )
    }

    @Test("Main display fallback still uses local fit and disables client resizing")
    func mainDisplayFallbackStillUsesLocalFitAndDisablesClientResizing() {
        #expect(
            desktopResizeUsesClientFitPresentation(
                captureSource: .mainDisplayFallback,
                clientFitFallbackActive: false
            )
        )
        #expect(
            !desktopResizeAllowsClientResize(
                captureSource: .mainDisplayFallback,
                clientFitFallbackActive: false
            )
        )
    }

    @MainActor
    @Test("New desktop session reset clears client-fit fallback state")
    func newDesktopSessionResetClearsClientFitFallbackState() {
        let service = MirageHostService()
        service.desktopClientFitFallbackActive = true
        service.desktopClientFitFallbackContainerResolution = CGSize(width: 1728, height: 1117)

        service.resetDesktopClientFitFallbackState()

        #expect(!service.desktopClientFitFallbackActive)
        #expect(service.desktopClientFitFallbackContainerResolution == nil)
    }

    @Test("Generation-change rebind is suppressed during resize transaction")
    func generationRebindSuppressedDuringResize() {
        let decision = desktopGenerationChangeRebindDecision(
            previousGeneration: 10,
            newGeneration: 11,
            sharedDisplayTransitionInFlight: true
        )

        #expect(decision == .skipSharedDisplayTransitionInFlight)
    }

    @Test("Generation-change rebind runs when resize is idle")
    func generationRebindRunsWhenResizeIsIdle() {
        let decision = desktopGenerationChangeRebindDecision(
            previousGeneration: 10,
            newGeneration: 11,
            sharedDisplayTransitionInFlight: false
        )

        #expect(decision == .rebind)
    }

    @Test("Deferred topology refresh matching committed resize is coalesced")
    func deferredTopologyRefreshMatchingCommittedResizeIsCoalesced() {
        #expect(
            desktopTopologyRefreshMatchesCommittedResize(
                reason: "screen_parameters_changed_deferred",
                committedResizePixelResolution: CGSize(width: 2448, height: 1408),
                requestedVirtualResolution: CGSize(width: 2448, height: 1408),
                currentVirtualResolution: CGSize(width: 2448, height: 1408)
            )
        )
        #expect(
            !desktopTopologyRefreshMatchesCommittedResize(
                reason: "screen_parameters_changed",
                committedResizePixelResolution: CGSize(width: 2448, height: 1408),
                requestedVirtualResolution: CGSize(width: 2448, height: 1408),
                currentVirtualResolution: CGSize(width: 2448, height: 1408)
            )
        )
        #expect(
            !desktopTopologyRefreshMatchesCommittedResize(
                reason: "screen_parameters_changed_deferred",
                committedResizePixelResolution: CGSize(width: 2448, height: 1408),
                requestedVirtualResolution: CGSize(width: 2080, height: 1184),
                currentVirtualResolution: CGSize(width: 2080, height: 1184)
            )
        )
    }

    @Test("Desktop mirroring restore aborts when stream is inactive")
    func desktopMirroringRestoreAbortsWhenStreamIsInactive() {
        let decision = desktopMirroringRestoreContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: nil,
            hasDesktopContext: false,
            desktopStreamMode: .unified
        )

        #expect(decision == .abortStreamInactive)
    }

    @Test("Desktop mirroring restore aborts when desktop mode changed")
    func desktopMirroringRestoreAbortsWhenModeChanges() {
        let decision = desktopMirroringRestoreContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: 41,
            hasDesktopContext: true,
            desktopStreamMode: .secondary
        )

        #expect(decision == .abortModeChanged)
    }

    @Test("Desktop mirroring restore continues only for unified active stream")
    func desktopMirroringRestoreContinuesForUnifiedStream() {
        let decision = desktopMirroringRestoreContinuationDecision(
            requestedStreamID: 41,
            activeDesktopStreamID: 41,
            hasDesktopContext: true,
            desktopStreamMode: .unified
        )

        #expect(decision == .continueRestore)
    }

    @Test("Display space snapshot ignores invalid zero Space IDs")
    func displaySpaceSnapshotIgnoresInvalidSpaces() {
        let snapshot = capturedDisplaySpaceSnapshot(displayIDs: [1, 2, 3]) { displayID in
            switch displayID {
            case 1:
                101
            case 2:
                0
            default:
                303
            }
        }

        #expect(snapshot == [1: 101, 3: 303])
    }

    @Test("Pending display space restores only returns actionable mismatched displays")
    func pendingDisplaySpaceRestoresOnlyReturnsActionableMismatches() {
        let pending = pendingDisplaySpaceRestores(
            snapshot: [1: 101, 2: 202, 3: 303]
        ) { displayID in
            switch displayID {
            case 1:
                101
            case 2:
                999
            default:
                0
            }
        }

        #expect(pending == [2: 202])
    }

    @Test("Window resize no-op applies when display matches but visible differs")
    func windowResizeNoOpAppliesWhenOnlyDisplayMatches() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 6016, height: 3324),
            currentDisplayResolution: CGSize(width: 6016, height: 3384),
            currentEncodedResolution: CGSize(width: 6016, height: 3384),
            requestedVisibleResolution: CGSize(width: 6016, height: 3384)
        )

        #expect(decision == .apply)
    }

    @Test("Window resize no-op regression: inset-calibrated visible mismatch must apply")
    func windowResizeNoOpRegressionInsetVisibleMismatch() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 2450, height: 1548),
            currentDisplayResolution: CGSize(width: 2450, height: 1608),
            currentEncodedResolution: CGSize(width: 2450, height: 1608),
            requestedVisibleResolution: CGSize(width: 2450, height: 1608)
        )

        #expect(decision == .apply)
    }

    @Test("Window resize no-op applies when encoded dimensions still lag requested visible size")
    func windowResizeNoOpAppliesWhenEncodedDimensionsLag() {
        let decision = windowResizeNoOpDecision(
            currentVisibleResolution: CGSize(width: 2420, height: 1668),
            currentDisplayResolution: CGSize(width: 2420, height: 1668),
            currentEncodedResolution: CGSize(width: 2416, height: 1664),
            requestedVisibleResolution: CGSize(width: 2420, height: 1668)
        )

        #expect(decision == .apply)
    }

    @Test("Placement bounds decision prefers recomputed bounds when cached bounds are outside display")
    func placementBoundsDecisionPrefersRecomputedWhenCachedOutsideDisplay() {
        let recomputed = CGRect(x: 2056, y: 30, width: 1528, height: 1218)
        let decision = placementBoundsSelectionDecision(
            cachedBounds: CGRect(x: 3584, y: 30, width: 1528, height: 1218),
            recomputedBounds: recomputed,
            displayBounds: CGRect(x: 2056, y: 0, width: 1528, height: 1248)
        )

        #expect(decision.outcome == .adoptRecomputedCachedOutsideDisplay)
        #expect(decision.resolvedBounds == recomputed)
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

    @Test("Headless-only Mirage display skips separation configuration when already at origin")
    func headlessOnlyMirageDisplaySkipsSeparationConfigurationAtOrigin() {
        let display35: CGDirectDisplayID = 35

        #expect(
            shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35],
                isHeadless: true,
                virtualDisplayBounds: CGRect(x: 0, y: 0, width: 3000, height: 1688),
                mirrorSource: kCGNullDirectDisplay
            )
        )
    }

    @Test("Headless-only separation skip requires valid unmirrored origin display")
    func headlessOnlySeparationSkipRequiresValidUnmirroredOriginDisplay() {
        let display35: CGDirectDisplayID = 35
        let display37: CGDirectDisplayID = 37

        #expect(
            !shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35],
                isHeadless: false,
                virtualDisplayBounds: CGRect(x: 0, y: 0, width: 3000, height: 1688),
                mirrorSource: kCGNullDirectDisplay
            )
        )
        #expect(
            !shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35, display37],
                isHeadless: true,
                virtualDisplayBounds: CGRect(x: 0, y: 0, width: 3000, height: 1688),
                mirrorSource: kCGNullDirectDisplay
            )
        )
        #expect(
            !shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35],
                isHeadless: true,
                virtualDisplayBounds: CGRect(x: 10, y: 0, width: 3000, height: 1688),
                mirrorSource: kCGNullDirectDisplay
            )
        )
        #expect(
            !shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35],
                isHeadless: true,
                virtualDisplayBounds: CGRect(x: 0, y: 0, width: 3000, height: 1688),
                mirrorSource: display37
            )
        )
        #expect(
            !shouldSkipHeadlessOnlyDisplaySeparationConfiguration(
                virtualDisplayID: display35,
                displays: [display35],
                isHeadless: true,
                virtualDisplayBounds: CGRect(x: 0, y: 0, width: 0, height: 1688),
                mirrorSource: kCGNullDirectDisplay
            )
        )
    }

    @Test("Desktop mirroring excludes only the target Mirage display")
    func desktopMirroringExcludesOnlyMirageDisplays() {
        let display1: CGDirectDisplayID = 1
        let display2: CGDirectDisplayID = 2
        let mirageDisplay23: CGDirectDisplayID = 23
        let targetMirageDisplay24: CGDirectDisplayID = 24

        let displaysToMirror = desktopMirroringDisplayIDs(
            displays: [display1, display2, mirageDisplay23, targetMirageDisplay24],
            targetDisplayID: targetMirageDisplay24,
            isMirageDisplay: { $0 == mirageDisplay23 || $0 == targetMirageDisplay24 }
        )

        #expect(displaysToMirror == [display1, display2])
    }

    @Test("Desktop mirroring preserves multi-display fan-out for one shared target")
    func desktopMirroringPreservesMultiDisplayFanOut() {
        let display1: CGDirectDisplayID = 1
        let display2: CGDirectDisplayID = 2
        let display3: CGDirectDisplayID = 3
        let targetMirageDisplay24: CGDirectDisplayID = 24

        let displaysToMirror = desktopMirroringDisplayIDs(
            displays: [display1, display2, display3, targetMirageDisplay24],
            targetDisplayID: targetMirageDisplay24,
            isMirageDisplay: { $0 == targetMirageDisplay24 }
        )

        #expect(displaysToMirror == [display1, display2, display3])
    }

    @Test("Display mirroring target stability accepts matching target without residual Mirage displays")
    func displayMirroringTargetStabilityAcceptsStableTarget() {
        let targetMirageDisplay24: CGDirectDisplayID = 24

        let decision = displayMirroringTargetStabilityDecision(
            targetDisplayID: targetMirageDisplay24,
            onlineDisplayIDs: [3, targetMirageDisplay24],
            observedTargetPixelResolution: CGSize(width: 2720, height: 2032),
            expectedTargetPixelResolution: CGSize(width: 2720, height: 2032),
            isMirageDisplay: { $0 == targetMirageDisplay24 }
        )

        #expect(decision == .stable)
    }

    @Test("Display mirroring target stability waits for stale Mirage displays to disappear")
    func displayMirroringTargetStabilityWaitsForResidualMirageDisplays() {
        let staleMirageDisplay23: CGDirectDisplayID = 23
        let targetMirageDisplay24: CGDirectDisplayID = 24

        let decision = displayMirroringTargetStabilityDecision(
            targetDisplayID: targetMirageDisplay24,
            onlineDisplayIDs: [3, staleMirageDisplay23, targetMirageDisplay24],
            observedTargetPixelResolution: CGSize(width: 2720, height: 2032),
            expectedTargetPixelResolution: CGSize(width: 2720, height: 2032),
            isMirageDisplay: { $0 == staleMirageDisplay23 || $0 == targetMirageDisplay24 }
        )

        #expect(decision == .waitForResidualMirageDisplays([staleMirageDisplay23]))
    }

    @Test("Residual Mirage display policy blocks unowned online displays")
    func residualMirageDisplayPolicyBlocksUnownedOnlineDisplays() {
        let ownedMirageDisplay24: CGDirectDisplayID = 24
        let residualMirageDisplay25: CGDirectDisplayID = 25

        let decision = residualMirageDisplayCreationDecision(
            onlineDisplayIDs: [3, residualMirageDisplay25, ownedMirageDisplay24],
            ownedDisplayIDs: [ownedMirageDisplay24],
            isMirageDisplay: { $0 == residualMirageDisplay25 || $0 == ownedMirageDisplay24 }
        )

        #expect(decision == .block([residualMirageDisplay25]))
    }

    @Test("Residual Mirage display policy allows owned Mirage displays")
    func residualMirageDisplayPolicyAllowsOwnedDisplays() {
        let ownedMirageDisplay24: CGDirectDisplayID = 24

        let decision = residualMirageDisplayCreationDecision(
            onlineDisplayIDs: [3, ownedMirageDisplay24],
            ownedDisplayIDs: [ownedMirageDisplay24],
            isMirageDisplay: { $0 == ownedMirageDisplay24 }
        )

        #expect(decision == .allow)
    }

    @Test("Physical fallback mirroring ignores residual Mirage displays")
    func physicalFallbackMirroringIgnoresResidualMirageDisplays() {
        let staleMirageDisplay23: CGDirectDisplayID = 23
        let mainDisplay3: CGDirectDisplayID = 3

        let decision = displayMirroringTargetStabilityDecision(
            targetDisplayID: mainDisplay3,
            onlineDisplayIDs: [mainDisplay3, staleMirageDisplay23],
            observedTargetPixelResolution: CGSize(width: 5120, height: 2880),
            expectedTargetPixelResolution: CGSize(width: 5120, height: 2880),
            requiresResidualMirageDisplaysClear: false,
            isMirageDisplay: { $0 == staleMirageDisplay23 }
        )

        #expect(decision == .stable)
    }

    @Test("Display mirroring target stability waits for expected target mode")
    func displayMirroringTargetStabilityWaitsForExpectedTargetMode() {
        let targetMirageDisplay24: CGDirectDisplayID = 24
        let expectedResolution = CGSize(width: 2720, height: 2032)
        let observedResolution = CGSize(width: 1360, height: 1016)

        let decision = displayMirroringTargetStabilityDecision(
            targetDisplayID: targetMirageDisplay24,
            onlineDisplayIDs: [3, targetMirageDisplay24],
            observedTargetPixelResolution: observedResolution,
            expectedTargetPixelResolution: expectedResolution,
            isMirageDisplay: { $0 == targetMirageDisplay24 }
        )

        #expect(
            decision == .waitForExpectedMode(
                observed: observedResolution,
                expected: expectedResolution
            )
        )
    }

    @Test("SCDisplay size validation accepts tolerance and rejects stale dimensions")
    func scDisplaySizeValidationChecksExpectedResolution() {
        #expect(
            SharedVirtualDisplayManager.scDisplayResolutionMatches(
                observed: CGSize(width: 2720.5, height: 2032),
                expected: CGSize(width: 2720, height: 2032)
            )
        )
        #expect(
            SharedVirtualDisplayManager.scDisplayResolutionMatches(
                observed: CGSize(width: 1224, height: 704),
                expected: CGSize(width: 2448, height: 1408),
                expectedLogical: CGSize(width: 1224, height: 704)
            )
        )
        #expect(
            !SharedVirtualDisplayManager.scDisplayResolutionMatches(
                observed: CGSize(width: 1224, height: 704),
                expected: CGSize(width: 2448, height: 1408)
            )
        )
    }
}
#endif
