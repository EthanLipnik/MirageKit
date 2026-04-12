//
//  AppWindowCaptureDisplaySelectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("App Window Capture Display Selection")
struct AppWindowCaptureDisplaySelectionTests {
    @Test("Mirrored app capture uses mirrored display metadata and refresh cadence")
    func mirroredAppCaptureUsesMirroredDisplay() {
        let selection = StreamContext.windowCaptureDisplaySelection(
            sourceDisplayID: 41,
            mirroredDisplayID: 77,
            captureDisplayIsMirage: true
        )

        #expect(selection.captureDisplayID == 77)
        #expect(selection.usesDisplayRefreshCadence)
    }

    @Test("Direct app capture keeps source display metadata when no mirrored display is active")
    func directAppCaptureKeepsSourceDisplay() {
        let selection = StreamContext.windowCaptureDisplaySelection(
            sourceDisplayID: 41,
            mirroredDisplayID: nil,
            captureDisplayIsMirage: false
        )

        #expect(selection.captureDisplayID == 41)
        #expect(selection.usesDisplayRefreshCadence == false)
    }

    @Test("Window capture on a Mirage display still follows display cadence without explicit mirroring")
    func mirageDisplayStillUsesDisplayCadence() {
        let selection = StreamContext.windowCaptureDisplaySelection(
            sourceDisplayID: 41,
            mirroredDisplayID: nil,
            captureDisplayIsMirage: true
        )

        #expect(selection.captureDisplayID == 41)
        #expect(selection.usesDisplayRefreshCadence)
    }

    @Test("Mirrored app capture keeps source display placement bounds when available")
    func mirroredAppCaptureKeepsSourceDisplayPlacementBounds() {
        let sourceBounds = CGRect(x: 100, y: 80, width: 1_440, height: 900)
        let mirroredBounds = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)

        let resolvedBounds = StreamContext.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: sourceBounds,
            mirroredVisibleBounds: mirroredBounds
        )

        #expect(resolvedBounds == sourceBounds)
    }

    @Test("Mirrored app capture falls back to mirrored bounds when source placement is unavailable")
    func mirroredAppCaptureFallsBackToMirroredPlacementBounds() {
        let mirroredBounds = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)

        let resolvedBounds = StreamContext.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: .zero,
            mirroredVisibleBounds: mirroredBounds
        )

        #expect(resolvedBounds == mirroredBounds)
    }
}
#endif
