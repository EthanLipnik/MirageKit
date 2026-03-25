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
    @Test("6K desktop keeps Retina backing")
    func sixKDesktopKeepsRetinaBacking() {
        let logicalResolution = CGSize(width: 3008, height: 1692)
        let decision = resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 2.0
        )

        #expect(decision.scaleFactor == 2.0)
        #expect(decision.pixelResolution == CGSize(width: 6016, height: 3376))
    }

    @Test("1x scale factor produces 1x pixel resolution")
    func oneXScaleFactorProducesOneXPixelResolution() {
        let logicalResolution = CGSize(width: 3008, height: 1692)
        let decision = resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 1.0
        )

        #expect(decision.scaleFactor == 1.0)
        #expect(decision.pixelResolution == CGSize(width: 3008, height: 1680))
    }
}
#endif
