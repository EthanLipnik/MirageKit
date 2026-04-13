//
//  SharedDisplayAppPresentationLayoutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Shared Display App Presentation Layout")
struct SharedDisplayAppPresentationLayoutTests {
    @Test("Primary-only app framing keeps the presentation rect on the primary window")
    func primaryOnlyFramingKeepsPrimaryPresentationRect() {
        let layout = StreamContext.sharedDisplayAppPresentationLayout(
            primaryRect: CGRect(x: 100, y: 60, width: 1200, height: 800),
            clusterRect: CGRect(x: 104, y: 60, width: 1194, height: 800),
            outputSize: CGSize(width: 2256, height: 1696)
        )

        #expect(layout.presentationRect == layout.primaryRect)
        #expect(layout.contentRect == layout.destinationRect)
    }

    @Test("Auto widen switches to the full cluster when a supplementary window protrudes beyond tolerance")
    func autoWidenUsesClusterRectWhenSupplementaryWindowProtrudes() {
        let primaryRect = CGRect(x: 100, y: 60, width: 1200, height: 800)
        let clusterRect = CGRect(x: 72, y: 60, width: 1328, height: 800)

        let layout = StreamContext.sharedDisplayAppPresentationLayout(
            primaryRect: primaryRect,
            clusterRect: clusterRect,
            outputSize: CGSize(width: 2256, height: 1696)
        )

        #expect(layout.primaryRect == primaryRect)
        #expect(layout.clusterRect == clusterRect)
        #expect(layout.presentationRect == clusterRect)
        #expect(layout.contentRect == layout.destinationRect)
    }

    @Test("Destination rect aspect-fits the chosen presentation rect inside the fixed canvas")
    func destinationRectAspectFitsPresentationRectInsideFixedCanvas() {
        let layout = StreamContext.sharedDisplayAppPresentationLayout(
            primaryRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            clusterRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            outputSize: CGSize(width: 2256, height: 1696)
        )

        #expect(layout.destinationRect == CGRect(x: 0, y: 96, width: 2256, height: 1504))
        #expect(layout.contentRect == CGRect(x: 0, y: 96, width: 2256, height: 1504))
    }

    @Test("Capture source rect uses display-local coordinates")
    func captureSourceRectUsesDisplayLocalCoordinates() {
        let sourceRect = StreamContext.sharedDisplayAppCaptureSourceRect(
            presentationRect: CGRect(x: 1700, y: 80, width: 800, height: 600),
            displayBounds: CGRect(x: 1600, y: 0, width: 1440, height: 900)
        )

        #expect(sourceRect == CGRect(x: 100, y: 80, width: 800, height: 600))
    }

    @Test("Traffic-light mask content rect stays anchored to the primary window within a widened frame")
    func trafficLightMaskContentRectAnchorsToPrimaryWindowWithinWidenedFrame() {
        let mappedContentRect = StreamContext.sharedDisplayAppTrafficLightMaskContentRect(
            primaryRect: CGRect(x: 100, y: 0, width: 800, height: 500),
            presentationRect: CGRect(x: 0, y: 0, width: 1000, height: 500),
            contentRect: CGRect(x: 200, y: 100, width: 1000, height: 500),
            fullFrameRect: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )

        #expect(mappedContentRect == CGRect(x: 300, y: 100, width: 800, height: 500))
    }
}
#endif
