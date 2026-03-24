//
//  HostTrafficLightMaskGeometryResolverTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

@testable import MirageKitHost
import CoreGraphics
import CoreVideo
import Testing

#if os(macOS)
@Suite("Host Traffic Light Mask Geometry Resolver")
struct HostTrafficLightMaskGeometryResolverTests {
    @Test("AX-derived geometry computes cluster bounds from button frames")
    func axDerivedClusterRectFromButtonFrames() {
        let windowFrame = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let buttonFrames = [
            CGRect(x: 112, y: 862, width: 14, height: 14),
            CGRect(x: 132, y: 862, width: 14, height: 14),
            CGRect(x: 152, y: 862, width: 14, height: 14),
        ]

        let clusterRect = HostTrafficLightMaskGeometryResolver.clusterRectFromButtonFrames(
            buttonFrames,
            windowFramePoints: windowFrame
        )

        #expect(clusterRect != nil)
        #expect(clusterRect?.origin.x == 0)
        #expect(clusterRect?.origin.y == 0)
        #expect(clusterRect?.width == 76)
        #expect(clusterRect?.height == 46)
    }

    @Test("Fallback geometry uses policy constants when AX is unavailable")
    func fallbackGeometryUsesPolicyConstants() {
        let windowFrame = CGRect(x: 200, y: 200, width: 1000, height: 700)
        let geometry = HostTrafficLightMaskGeometryResolver.resolve(
            windowID: WindowID.max,
            windowFramePoints: windowFrame,
            appProcessID: nil
        )

        #expect(geometry.source == .fallback)
        #expect(geometry.clusterRectPoints.origin.x == 0)
        #expect(geometry.clusterRectPoints.origin.y == 0)
        #expect(geometry.clusterRectPoints.width == HostTrafficLightProtectionPolicy.fallbackClusterSize.width)
        #expect(geometry.clusterRectPoints.height == HostTrafficLightProtectionPolicy.fallbackClusterSize.height)
    }

    @Test("Hidden buttons state suppresses clone-stamp planning")
    func hiddenButtonsStateSuppressesPlanning() {
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

        guard case let .skip(reason) = decision else {
            Issue.record("Expected planning to skip when all traffic lights are hidden")
            return
        }
        #expect(reason == .hiddenTrafficLights)
    }

    @Test("Geometry cache helper invalidates on material frame drift")
    func geometryCacheDriftInvalidates() {
        let cachedGeometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 800, height: 600),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 96, height: 44),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let cache = HostTrafficLightMaskGeometryResolver.CacheEntry(
            geometry: cachedGeometry,
            sampledAt: 100,
            sampledWindowFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let stillValid = HostTrafficLightMaskGeometryResolver.shouldUseCached(
            cache,
            now: 100.2,
            windowFramePoints: CGRect(x: 2, y: 2, width: 804, height: 603),
            ttl: 0.35,
            frameTolerance: 6
        )
        #expect(stillValid)

        let invalidated = HostTrafficLightMaskGeometryResolver.shouldUseCached(
            cache,
            now: 100.2,
            windowFramePoints: CGRect(x: 12, y: 2, width: 804, height: 603),
            ttl: 0.35,
            frameTolerance: 6
        )
        #expect(!invalidated)
    }
}
#endif
