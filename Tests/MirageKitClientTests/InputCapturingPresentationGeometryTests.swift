//
//  InputCapturingPresentationGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Input Capturing Presentation Geometry")
struct InputCapturingPresentationGeometryTests {
    @Test("Input normalization clamps through the presented content rect")
    func inputNormalizationClampsThroughPresentedContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = CGRect(x: 80, y: 0, width: 1440, height: 900)

        let normalized = InputCapturingView.normalizedLocation(
            CGPoint(x: 20, y: 450),
            in: bounds,
            contentRect: contentRect
        )

        #expect(normalized == CGPoint(x: 0, y: 0.5))
    }

    @Test("Normalized app-stream pointer positions map back into the presented content rect")
    func normalizedPointerPositionsMapIntoPresentedContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = CGRect(x: 80, y: 0, width: 1440, height: 900)

        let localPoint = InputCapturingView.localPoint(
            forNormalizedPosition: CGPoint(x: 0.25, y: 0.75),
            in: bounds,
            contentRect: contentRect
        )

        #expect(localPoint == CGPoint(x: 440, y: 675))
    }
}
#endif
