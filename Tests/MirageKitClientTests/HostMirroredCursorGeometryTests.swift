//
//  HostMirroredCursorGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@MainActor
@Suite("Host Mirrored Cursor Geometry")
struct HostMirroredCursorGeometryTests {
    @Test("Normalized host cursor positions are clamped into view bounds")
    func normalizedPositionsClampIntoViewBounds() {
        let clamped = ScrollPhysicsCapturingNSView.clampedNormalizedCursorPosition(
            CGPoint(x: -0.25, y: 1.75)
        )

        #expect(clamped == CGPoint(x: 0, y: 1))
    }

    @Test("Normalized host cursor positions map into local view coordinates")
    func normalizedPositionsMapIntoLocalViewCoordinates() {
        let localPoint = ScrollPhysicsCapturingNSView.localPoint(
            forNormalizedCursorPosition: CGPoint(x: 0.25, y: 0.75),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(localPoint == CGPoint(x: 200, y: 150))
    }
}
#endif
