//
//  HostTrafficLightMaskGeometryResolverTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreVideo
import Testing

@Suite("Host Traffic Light Mask Geometry Resolver")
struct HostTrafficLightMaskGeometryResolverTests {

    @Test("Hidden buttons state still applies clone-stamp for sharing indicator")
    func hiddenButtonsStateStillAppliesCloneStamp() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 900, height: 600),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 96, height: 44),
            buttonsHiddenState: .init(close: true, minimize: true, zoom: true),
            source: .ax
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 0, y: 0, width: 1800, height: 1200),
            geometry: geometry
        )

        guard case .apply = decision else {
            Issue.record("Expected clone-stamp plan even when buttons are hidden (sharing indicator is always present)")
            return
        }
    }

}
#endif
