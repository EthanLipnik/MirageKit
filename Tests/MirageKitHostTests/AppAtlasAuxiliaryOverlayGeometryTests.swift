//
//  AppAtlasAuxiliaryOverlayGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Testing

@Suite("App Atlas Auxiliary Overlay Geometry")
struct AppAtlasAuxiliaryOverlayGeometryTests {
    @Test("Overlay placement converts host points into parent capture pixels")
    func overlayPlacementConvertsHostPointsIntoParentCapturePixels() {
        let destinationRect = AppAtlasMediaCoordinator.auxiliaryOverlayDestinationRect(
            parentFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            parentSourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1200),
            auxiliaryFrame: CGRect(x: 500, y: 250, width: 200, height: 100)
        )
        let inputRect = AppAtlasMediaCoordinator.normalizedOverlayInputRect(
            destinationRect: destinationRect,
            parentSourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1200)
        )

        #expect(destinationRect == CGRect(x: 800, y: 300, width: 400, height: 200))
        #expect(inputRect.origin.x == 0.5)
        #expect(inputRect.origin.y == 0.25)
        #expect(inputRect.width == 0.25)
        #expect(abs(inputRect.height - (1.0 / 6.0)) < 0.0001)
    }

    @Test("Overlay placement clamps outside rects without resizing")
    func overlayPlacementClampsOutsideRectsWithoutResizing() {
        let destinationRect = AppAtlasMediaCoordinator.auxiliaryOverlayDestinationRect(
            parentFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            parentSourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1200),
            auxiliaryFrame: CGRect(x: 850, y: 650, width: 200, height: 100)
        )

        #expect(destinationRect == CGRect(x: 1200, y: 1000, width: 400, height: 200))
    }

    @Test("Overlay placement scales oversized auxiliaries to fit parent surface")
    func overlayPlacementScalesOversizedAuxiliariesToFitParentSurface() {
        let destinationRect = AppAtlasMediaCoordinator.auxiliaryOverlayDestinationRect(
            parentFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            parentSourceRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            auxiliaryFrame: CGRect(x: 0, y: 0, width: 1600, height: 1200)
        )

        #expect(destinationRect == CGRect(x: 0, y: 0, width: 800, height: 600))
    }
}
#endif
