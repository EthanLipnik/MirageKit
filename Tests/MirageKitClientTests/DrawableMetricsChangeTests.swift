//
//  DrawableMetricsChangeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/22/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Drawable Metrics Change Detection")
struct DrawableMetricsChangeTests {
    @Test("Screen metric changes are reported when drawable pixels are unchanged")
    func screenMetricChangesAreReportedWhenDrawablePixelsAreUnchanged() {
        let previous = MirageDrawableMetrics(
            pixelSize: CGSize(width: 2732, height: 2048),
            viewSize: CGSize(width: 1366, height: 1024),
            scaleFactor: 2,
            screenPointSize: CGSize(width: 1366, height: 1024),
            screenScale: 2,
            screenNativePixelSize: CGSize(width: 2732, height: 2048),
            screenNativeScale: 2
        )
        let next = MirageDrawableMetrics(
            pixelSize: CGSize(width: 2732, height: 2048),
            viewSize: CGSize(width: 1366, height: 1024),
            scaleFactor: 2,
            screenPointSize: CGSize(width: 1512, height: 1134),
            screenScale: 2,
            screenNativePixelSize: CGSize(width: 2732, height: 2048),
            screenNativeScale: 2
        )

        #expect(MirageDrawableMetrics.shouldReportChange(from: previous, to: next))
        #expect(!MirageDrawableMetrics.shouldReportChange(from: previous, to: previous))
    }
}
