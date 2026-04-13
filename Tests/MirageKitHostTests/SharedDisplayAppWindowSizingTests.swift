//
//  SharedDisplayAppWindowSizingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

#if os(macOS)
@Suite("Shared Display App Window Sizing")
struct SharedDisplayAppWindowSizingTests {
    @Test("Placement bounds prefer mirrored visible frame")
    func placementBoundsPreferMirroredVisibleFrame() {
        let sourceVisibleBounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let mirroredVisibleBounds = CGRect(x: 0, y: 30, width: 1376, height: 928)

        let resolved = StreamContext.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: sourceVisibleBounds,
            mirroredVisibleBounds: mirroredVisibleBounds
        )

        #expect(resolved == mirroredVisibleBounds)
    }

    @Test("Startup frame uses preset aspect ratio inside visible bounds")
    func startupFrameUsesPresetAspectRatioInsideVisibleBounds() {
        let visibleBounds = CGRect(x: 0, y: 30, width: 1376, height: 928)
        let aspectRatio = StreamContext.targetWindowAspectRatio(
            requestedLogicalSize: CGSize(width: 1600, height: 1200),
            sizePreset: .standard
        )

        let resolved = StreamContext.aspectFittedFrame(
            within: visibleBounds,
            aspectRatio: aspectRatio
        )

        #expect(resolved == CGRect(x: 69, y: 30, width: 1237, height: 928))
    }

    @Test("Resize no-op accepts existing best-fit bounds")
    func resizeNoOpAcceptsExistingBestFitBounds() {
        let decision = windowResizePlacementNoOpDecision(
            currentBounds: CGRect(x: 69, y: 30, width: 1237, height: 928),
            displayVisibleBounds: CGRect(x: 0, y: 30, width: 1376, height: 928),
            requestedAspectRatio: MirageDisplaySizePreset.standard.contentAspectRatio
        )

        #expect(decision == .noOp)
    }

    @Test("Resize no-op applies when requested aspect changes")
    func resizeNoOpAppliesWhenRequestedAspectChanges() {
        let decision = windowResizePlacementNoOpDecision(
            currentBounds: CGRect(x: 69, y: 30, width: 1237, height: 928),
            displayVisibleBounds: CGRect(x: 0, y: 30, width: 1376, height: 928),
            requestedAspectRatio: MirageDisplaySizePreset.large.contentAspectRatio
        )

        #expect(decision == .apply)
    }
}
#endif
