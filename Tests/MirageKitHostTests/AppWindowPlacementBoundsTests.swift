//
//  AppWindowPlacementBoundsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("App Window Placement Bounds")
struct AppWindowPlacementBoundsTests {
    @Test("Mirrored app capture prefers mirrored visible placement bounds")
    func mirroredAppCapturePrefersMirroredDisplayPlacementBounds() {
        let sourceBounds = CGRect(x: 100, y: 80, width: 1_440, height: 900)
        let mirroredBounds = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)

        let resolvedBounds = StreamContext.mirroredAppWindowPlacementBounds(
            sourceVisibleBounds: sourceBounds,
            mirroredVisibleBounds: mirroredBounds
        )

        #expect(resolvedBounds == mirroredBounds)
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
