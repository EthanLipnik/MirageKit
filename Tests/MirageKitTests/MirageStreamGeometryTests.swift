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

    @Test("Geometry preserves aspect when 1080p cap requires aligned dimensions")
    func geometryPreservesAspectWhen1080pCapRequiresAlignedDimensions() {
        let geometry = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: CGSize(width: 2752, height: 2064),
            requestedStreamScale: 1.0,
            encoderMaxWidth: 1920,
            encoderMaxHeight: 1080
        )

        let aspect = geometry.encodedPixelSize.width / geometry.encodedPixelSize.height
        #expect(geometry.encodedPixelSize == CGSize(width: 1424, height: 1072))
        #expect(abs(aspect - (4.0 / 3.0)) < 0.005)
    }

    @Test("Geometry ignores encoder limits when resolution caps are disabled")
    func geometryIgnoresEncoderLimitsWhenResolutionCapsAreDisabled() {
        let geometry = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: CGSize(width: 8240, height: 4000),
            requestedStreamScale: 1.0,
            encoderMaxWidth: 3840,
            encoderMaxHeight: 2160,
            disableResolutionCap: true
        )

        #expect(geometry.encodedPixelSize == CGSize(width: 8240, height: 4000))
        #expect(geometry.resolvedStreamScale == 1.0)
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

    @Test("Geometry can preserve desktop aspect at report-like low scale")
    func geometryCanPreserveDesktopAspectAtReportLikeLowScale() {
        let geometry = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: CGSize(width: 2448, height: 1408),
            requestedStreamScale: 752.0 / 2448.0,
            disableResolutionCap: true
        )

        let aspect = geometry.encodedPixelSize.width / geometry.encodedPixelSize.height
        let baseAspect = 2448.0 / 1408.0
        #expect(geometry.encodedPixelSize == CGSize(width: 752, height: 432))
        #expect(geometry.encodedPixelSize != CGSize(width: 736, height: 416))
        #expect(abs(aspect - baseAspect) / baseAspect < 0.002)
    }

    @Test("Desktop geometry contract identity compares resolved display and encoded pixels")
    func desktopGeometryContractIdentityComparesResolvedDisplayAndEncodedPixels() {
        let startup = DesktopGeometryContract(
            logicalSize: CGSize(width: 1600, height: 1200),
            requestedDisplayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )
        let firstDrawable = DesktopGeometryContract(
            logicalSize: CGSize(width: 1600, height: 1200),
            requestedDisplayScaleFactor: 2.0,
            requestedStreamScale: 0.86,
            encoderMaxWidth: 2752,
            encoderMaxHeight: 2064
        )

        #expect(startup.requestedStreamScale != firstDrawable.requestedStreamScale)
        #expect(startup.resolvedStreamScale == firstDrawable.resolvedStreamScale)
        #expect(startup.identity == firstDrawable.identity)
    }
}
