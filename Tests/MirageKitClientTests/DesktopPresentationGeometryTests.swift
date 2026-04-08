//
//  DesktopPresentationGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Presentation Geometry")
struct DesktopPresentationGeometryTests {
    @Test("Desktop presentation aspect-fits the stream inside the macOS view bounds")
    func desktopPresentationAspectFitsInsideViewBounds() {
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: CGRect(x: 0, y: 0, width: 1600, height: 900)
        )

        #expect(contentRect == CGRect(x: 80, y: 0, width: 1440, height: 900))
    }

    @Test("Absolute mouse normalization clamps through the desktop content rect")
    func absoluteMouseNormalizationClampsThroughDesktopContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: bounds
        )

        let normalized = ScrollPhysicsCapturingNSView.normalizedLocation(
            CGPoint(x: 20, y: 450),
            in: bounds,
            contentRect: contentRect
        )

        #expect(normalized == CGPoint(x: 0, y: 0.5))
    }

    @Test("Mirrored cursor positions map through the desktop content rect")
    func mirroredCursorPositionsMapThroughDesktopContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: bounds
        )

        let localPoint = ScrollPhysicsCapturingNSView.localPoint(
            forNormalizedCursorPosition: CGPoint(x: 0.25, y: 0.75),
            in: bounds,
            contentRect: contentRect
        )

        #expect(localPoint == CGPoint(x: 440, y: 225))
    }
}
#endif
