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
}
#endif
