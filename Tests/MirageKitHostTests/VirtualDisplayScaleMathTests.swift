//
//  VirtualDisplayScaleMathTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Scale math coverage for virtual display fallback and bounds sizing.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Virtual Display Scale Math")
struct VirtualDisplayScaleMathTests {
    @Test("Logical resolution uses active scale factor")
    func logicalResolutionUsesActiveScaleFactor() {
        let pixel = CGSize(width: 6016, height: 3384)
        let logical = SharedVirtualDisplayManager.logicalResolution(for: pixel, scaleFactor: 2.0)

        #expect(logical.width == 3008)
        #expect(logical.height == 1692)
    }

    @Test("Logical resolution keeps 1x dimensions")
    func logicalResolutionKeepsOneXDimensions() {
        let pixel = CGSize(width: 3008, height: 1692)
        let logical = SharedVirtualDisplayManager.logicalResolution(for: pixel, scaleFactor: 1.0)

        #expect(logical.width == 3008)
        #expect(logical.height == 1692)
    }

    @Test("Fallback resolution returns even 1x target")
    func fallbackResolutionReturnsEvenOneXTarget() {
        let fallback = SharedVirtualDisplayManager.fallbackResolution(
            for: CGSize(width: 6017, height: 3385)
        )

        #expect(fallback.width == 3008)
        #expect(fallback.height == 1680)
    }
}
#endif
