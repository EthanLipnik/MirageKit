//
//  DesktopBackingScaleResolutionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/6/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Backing Scale Resolution")
struct DesktopBackingScaleResolutionTests {
    @Test("Uncapped 6K desktop keeps Retina backing")
    func uncappedSixKDesktopKeepsRetinaBacking() {
        let logicalResolution = CGSize(width: 3008, height: 1692)
        let decision = resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 2.0,
            streamScale: 1.0,
            disableResolutionCap: true
        )

        #expect(decision.scaleFactor == 2.0)
        #expect(decision.pixelResolution == CGSize(width: 6016, height: 3384))
        #expect(!decision.forcedOneX)
    }

    @Test("Capped desktop above 1080p keeps Retina backing")
    func cappedDesktopAbove1080pKeepsRetinaBacking() {
        let logicalResolution = CGSize(width: 3008, height: 1692)
        let decision = resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 2.0,
            streamScale: 0.50,
            disableResolutionCap: false
        )

        #expect(decision.scaleFactor == 2.0)
        #expect(decision.pixelResolution == CGSize(width: 6016, height: 3384))
        #expect(!decision.forcedOneX)
    }

    @Test("Capped desktop at or below 1080p forces 1x backing")
    func cappedDesktopAtOrBelow1080pForcesOneXBacking() {
        let logicalResolution = CGSize(width: 3008, height: 1692)
        let decision = resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 2.0,
            streamScale: 1280.0 / 6016.0,
            disableResolutionCap: false
        )

        #expect(decision.scaleFactor == 1.0)
        #expect(decision.pixelResolution == logicalResolution)
        #expect(decision.predictedEncodedResolution == CGSize(width: 1280, height: 720))
        #expect(decision.forcedOneX)
    }
}
#endif
