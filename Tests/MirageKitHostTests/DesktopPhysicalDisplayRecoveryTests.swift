//
//  DesktopPhysicalDisplayRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Physical Display Recovery")
struct DesktopPhysicalDisplayRecoveryTests {
    @Test("Primary physical bounds preserve last known good geometry during transient zero refresh")
    func primaryPhysicalBoundsPreserveLastKnownGoodGeometryDuringTransientZeroRefresh() {
        let cachedBounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let snapshot = MirageHostService.resolvedDesktopPrimaryPhysicalDisplaySnapshot(
            cachedDisplayID: 21,
            cachedBounds: cachedBounds,
            resolvedPrimaryDisplayID: 44,
            mainDisplayID: 99,
            boundsProvider: { _ in .zero }
        )

        #expect(snapshot.displayID == 21)
        #expect(snapshot.bounds == cachedBounds)
    }

    @Test("Primary physical bounds switch to a live physical display once topology settles")
    func primaryPhysicalBoundsSwitchToLivePhysicalDisplayOnceTopologySettles() {
        let expectedBounds = CGRect(x: 50, y: 20, width: 3024, height: 1964)
        let snapshot = MirageHostService.resolvedDesktopPrimaryPhysicalDisplaySnapshot(
            cachedDisplayID: 21,
            cachedBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            resolvedPrimaryDisplayID: 44,
            mainDisplayID: 99,
            boundsProvider: { displayID in
                if displayID == 44 {
                    expectedBounds
                } else {
                    .zero
                }
            }
        )

        #expect(snapshot.displayID == 44)
        #expect(snapshot.bounds == expectedBounds)
    }

    @Test("Setup guard cursor uses captured point after mirroring changes bounds")
    func setupGuardCursorUsesCapturedPointAfterMirroringChangesBounds() {
        let preMirroringPoint = CGPoint(x: 1440, y: 773)
        let mirroredVirtualBounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)

        let point = MirageHostService.resolvedVirtualDisplaySetupCursorPoint(
            cursorAnchorPoint: preMirroringPoint,
            visibleBounds: mirroredVirtualBounds
        )

        #expect(point == preMirroringPoint)
    }

    @Test("Setup guard cursor falls back to visible bounds without a captured point")
    func setupGuardCursorFallsBackToVisibleBoundsWithoutCapturedPoint() {
        let visibleBounds = CGRect(x: 100, y: 50, width: 2880, height: 1546)

        let point = MirageHostService.resolvedVirtualDisplaySetupCursorPoint(
            cursorAnchorPoint: nil,
            visibleBounds: visibleBounds
        )

        #expect(point == CGPoint(x: 1540, y: 823))
    }
}
#endif
