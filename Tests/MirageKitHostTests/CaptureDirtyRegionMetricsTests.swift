//
//  CaptureDirtyRegionMetricsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

@Suite("Capture Dirty Region Metrics")
struct CaptureDirtyRegionMetricsTests {
    @Test("Tiny dirty rect reports area percentage")
    func tinyDirtyRectReportsAreaPercentage() {
        let percent = dirtyPercentage([CGRect(x: 10, y: 10, width: 10, height: 10)])

        expectApproximately(percent, 1.0)
    }

    @Test("Multiple dirty rects add non-overlapping area")
    func multipleDirtyRectsAddNonOverlappingArea() {
        let percent = dirtyPercentage([
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 90, y: 90, width: 10, height: 10),
        ])

        expectApproximately(percent, 2.0)
    }

    @Test("Overlapping dirty rects count union area once")
    func overlappingDirtyRectsCountUnionAreaOnce() {
        let percent = dirtyPercentage([
            CGRect(x: 0, y: 0, width: 50, height: 50),
            CGRect(x: 25, y: 0, width: 50, height: 50),
        ])

        expectApproximately(percent, 37.5)
    }

    @Test("Out-of-bounds dirty rects are clipped to content")
    func outOfBoundsDirtyRectsAreClippedToContent() {
        let percent = CaptureDirtyRegionMetrics.dirtyPercentage(
            dirtyRectsValue: [CGRect(x: -25, y: 0, width: 50, height: 100)],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fullRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            isIdleFrame: false
        )

        expectApproximately(percent, 25.0)
    }

    @Test("Empty dirty rects report no dirty area")
    func emptyDirtyRectsReportNoDirtyArea() {
        let percent = dirtyPercentage([])

        expectApproximately(percent, 0)
    }

    @Test("Missing dirty metadata remains conservative")
    func missingDirtyMetadataRemainsConservative() {
        let percent = CaptureDirtyRegionMetrics.dirtyPercentage(
            dirtyRectsValue: nil,
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fullRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            isIdleFrame: false
        )

        expectApproximately(percent, 100)
    }

    @Test("Idle frames report no dirty area")
    func idleFramesReportNoDirtyArea() {
        let percent = CaptureDirtyRegionMetrics.dirtyPercentage(
            dirtyRectsValue: [CGRect(x: 0, y: 0, width: 100, height: 100)],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fullRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            isIdleFrame: true
        )

        expectApproximately(percent, 0)
    }

    @Test("Dictionary dirty rects are parsed")
    func dictionaryDirtyRectsAreParsed() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 10)
        let dictionary = rect.dictionaryRepresentation as NSDictionary
        let percent = dirtyPercentage([dictionary])

        expectApproximately(percent, 2.0)
    }

    private func dirtyPercentage(_ dirtyRects: Any) -> Float {
        CaptureDirtyRegionMetrics.dirtyPercentage(
            dirtyRectsValue: dirtyRects,
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fullRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            isIdleFrame: false
        )
    }

    private func expectApproximately(_ actual: Float, _ expected: Float) {
        #expect(abs(actual - expected) < 0.001)
    }
}
#endif
