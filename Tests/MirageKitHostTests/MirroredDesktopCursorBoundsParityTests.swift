//
//  MirroredDesktopCursorBoundsParityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Mirrored Desktop Cursor Bounds Parity")
struct MirroredDesktopCursorBoundsParityTests {
    @Test("Mirrored desktop cursor monitor bounds reuse the aspect-fitted input rect")
    func mirroredDesktopCursorMonitorBoundsReuseInputRect() {
        let physicalBounds = CGRect(x: 200, y: 120, width: 1920, height: 1080)
        let virtualResolution = CGSize(width: 2560, height: 1600)
        let primaryHeight: CGFloat = 1600

        let inputBounds = MirageHostService.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )
        let cursorMonitorBounds = MirageHostService.resolvedMirroredDesktopCursorMonitorBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution,
            primaryHeight: primaryHeight
        )

        #expect(cursorMonitorBounds.width == inputBounds.width)
        #expect(cursorMonitorBounds.height == inputBounds.height)
        #expect(cursorMonitorBounds.minX == inputBounds.minX)
        #expect(cursorMonitorBounds.minY == primaryHeight - inputBounds.maxY)
    }

    @Test("Mirrored desktop cursor monitor normalization matches input normalization")
    func mirroredDesktopCursorMonitorNormalizationMatchesInputNormalization() {
        let physicalBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let virtualResolution = CGSize(width: 2560, height: 1600)
        let primaryHeight: CGFloat = 1440
        let expectedNormalized = CGPoint(x: 0.25, y: 0.7)

        let inputBounds = MirageHostService.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )
        let cursorMonitorBounds = MirageHostService.resolvedMirroredDesktopCursorMonitorBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution,
            primaryHeight: primaryHeight
        )

        let inputPoint = CGPoint(
            x: inputBounds.minX + expectedNormalized.x * inputBounds.width,
            y: inputBounds.minY + expectedNormalized.y * inputBounds.height
        )
        let cocoaPoint = CGPoint(x: inputPoint.x, y: primaryHeight - inputPoint.y)
        let monitorNormalized = CGPoint(
            x: (cocoaPoint.x - cursorMonitorBounds.minX) / cursorMonitorBounds.width,
            y: 1.0 - ((cocoaPoint.y - cursorMonitorBounds.minY) / cursorMonitorBounds.height)
        )

        #expect(abs(monitorNormalized.x - expectedNormalized.x) < 0.0001)
        #expect(abs(monitorNormalized.y - expectedNormalized.y) < 0.0001)
    }

    @Test("Mirrored desktop cursor start point uses the center of the aspect-fitted input rect")
    func mirroredDesktopCursorStartPointUsesAspectFittedCenter() {
        let physicalBounds = CGRect(x: 0, y: 0, width: 2880, height: 1620)
        let virtualResolution = CGSize(width: 2752, height: 2064)
        let inputBounds = MirageHostService.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )

        let startPoint = MirageHostService.resolvedDesktopCursorStartPoint(inputBounds: inputBounds)

        #expect(startPoint == CGPoint(x: inputBounds.midX, y: inputBounds.midY))
        #expect(startPoint == CGPoint(x: physicalBounds.midX, y: physicalBounds.midY))
    }

    @Test("Mirrored desktop input bounds follow virtual resolution changes")
    func mirroredDesktopInputBoundsFollowVirtualResolutionChanges() {
        let physicalBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let oldVirtualResolution = CGSize(width: 2560, height: 1600)
        let newVirtualResolution = CGSize(width: 2048, height: 1536)
        let normalizedPoint = CGPoint(x: 0, y: 0.5)

        let oldInputBounds = MirageHostService.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: oldVirtualResolution
        )
        let newInputBounds = MirageHostService.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: newVirtualResolution
        )
        let oldMappedPoint = CGPoint(
            x: oldInputBounds.minX + normalizedPoint.x * oldInputBounds.width,
            y: oldInputBounds.minY + normalizedPoint.y * oldInputBounds.height
        )
        let newMappedPoint = CGPoint(
            x: newInputBounds.minX + normalizedPoint.x * newInputBounds.width,
            y: newInputBounds.minY + normalizedPoint.y * newInputBounds.height
        )

        #expect(oldInputBounds != newInputBounds)
        #expect(newInputBounds.minX > oldInputBounds.minX)
        #expect(newMappedPoint.x > oldMappedPoint.x)
        #expect(newMappedPoint.y == oldMappedPoint.y)
    }
}
#endif
