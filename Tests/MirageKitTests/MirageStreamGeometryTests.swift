//
//  MirageStreamGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKit
import CoreGraphics
import Testing

@Suite("Mirage Stream Geometry")
struct MirageStreamGeometryTests {
    @Test("Geometry canonicalizes Vision Pro startup dimensions to aligned pixels")
    func geometryCanonicalizesVisionProStartupDimensionsToAlignedPixels() {
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: CGSize(width: 440, height: 956),
            displayScaleFactor: 3.0
        )

        #expect(geometry.logicalSize == CGSize(width: 440, height: 956))
        #expect(geometry.displayPixelSize == CGSize(width: 1312, height: 2864))
        #expect(abs(geometry.displayScaleFactor - 2.988) < 0.01)
        #expect(geometry.encodedPixelSize == CGSize(width: 1312, height: 2864))
    }

    @Test("Geometry preserves mixed-scale desktop startup pixel size deterministically")
    func geometryPreservesMixedScaleDesktopStartupPixelSizeDeterministically() {
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72
        )

        #expect(geometry.displayPixelSize == CGSize(width: 2752, height: 2064))
        #expect(geometry.encodedPixelSize == CGSize(width: 2752, height: 2064))
    }

    @Test("Geometry resolves capped startup stream scale from canonical base pixels")
    func geometryResolvesCappedStartupStreamScaleFromCanonicalBasePixels() {
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: CGSize(width: 1600, height: 1200),
            displayScaleFactor: 1.72,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2048,
            encoderMaxHeight: 1536
        )

        #expect(abs(geometry.resolvedStreamScale - (2048.0 / 2752.0)) < 0.001)
        #expect(geometry.encodedPixelSize == CGSize(width: 2048, height: 1536))
    }

    @Test("Geometry honors explicit encoder limits even when default caps are disabled")
    func geometryHonorsExplicitEncoderLimitsWhenDefaultCapsAreDisabled() {
        let geometry = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: CGSize(width: 8240, height: 4000),
            requestedStreamScale: 1.0,
            encoderMaxWidth: 3840,
            encoderMaxHeight: 2160,
            disableResolutionCap: true
        )

        #expect(geometry.encodedPixelSize.width <= 3840)
        #expect(geometry.encodedPixelSize.height <= 2160)
        #expect(geometry.resolvedStreamScale < 1.0)
    }

    @Test("Geometry keeps uncapped scale when no explicit encoder limit exists")
    func geometryKeepsUncappedScaleWithoutExplicitEncoderLimit() {
        let geometry = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: CGSize(width: 8240, height: 4000),
            requestedStreamScale: 1.0,
            disableResolutionCap: true
        )

        #expect(geometry.encodedPixelSize == CGSize(width: 8240, height: 4000))
        #expect(geometry.resolvedStreamScale == 1.0)
    }
}
