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
@Suite("Host Cursor Geometry")
struct HostMirroredCursorGeometryTests {
    @Test("Mirrored desktop cursor positions clamp into view bounds")
    func mirroredPositionsClampIntoViewBounds() {
        let clamped = ScrollPhysicsCapturingNSView.normalizedCursorPosition(
            CGPoint(x: -0.25, y: 1.75),
            allowsExtendedBounds: false
        )

        #expect(clamped == CGPoint(x: 0, y: 1))
    }

    @Test("Secondary desktop cursor positions allow speculative overflow without confirmed host position")
    func secondaryPositionsAllowSpeculativeOverflowWithoutConfirmedHostPosition() {
        let position = ScrollPhysicsCapturingNSView.normalizedCursorPosition(
            CGPoint(x: 1.35, y: -0.2),
            allowsExtendedBounds: true
        )

        #expect(position == CGPoint(x: 1.35, y: -0.2))
    }

    @Test("Locked cursor button events clamp into bounds for mirrored display mode")
    func lockedCursorButtonEventsClampIntoBounds() {
        let clamped = LockedCursorPositionResolver.resolve(
            CGPoint(x: 1.35, y: -0.2),
            allowsExtendedBounds: false
        )

        #expect(clamped == CGPoint(x: 1, y: 0))
    }

    @Test("Locked cursor allows speculative overflow when no host position is confirmed")
    func lockedCursorAllowsSpeculativeOverflowWithoutConfirmedHostPosition() {
        let position = LockedCursorPositionResolver.resolve(
            CGPoint(x: 1.35, y: -0.2),
            allowsExtendedBounds: true
        )

        #expect(position == CGPoint(x: 1.35, y: -0.2))
    }

    @Test("Secondary desktop locked cursor limits speculative overscroll at blocked edges")
    func secondaryLockedCursorLimitsSpeculativeOverscroll() {
        let position = LockedCursorPositionResolver.resolve(
            CGPoint(x: 1.8, y: -0.7),
            allowsExtendedBounds: true,
            confirmedHostPosition: CGPoint(x: 1, y: 0)
        )

        #expect(abs(position.x - 1.35) < 0.0001)
        #expect(abs(position.y + 0.35) < 0.0001)
    }

    @Test("Secondary desktop locked cursor follows confirmed off-display host travel")
    func secondaryLockedCursorFollowsConfirmedOffDisplayHostTravel() {
        let position = LockedCursorPositionResolver.resolve(
            CGPoint(x: 1.7, y: -0.6),
            allowsExtendedBounds: true,
            confirmedHostPosition: CGPoint(x: 1.2, y: -0.15)
        )

        #expect(abs(position.x - 1.55) < 0.0001)
        #expect(abs(position.y + 0.5) < 0.0001)
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
