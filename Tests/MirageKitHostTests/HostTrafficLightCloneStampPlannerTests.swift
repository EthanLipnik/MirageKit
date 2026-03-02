//
//  HostTrafficLightCloneStampPlannerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

@testable import MirageKitHost
import CoreGraphics
import CoreVideo
import Testing

#if os(macOS)
@Suite("Host Traffic Light Clone-Stamp Planner")
struct HostTrafficLightCloneStampPlannerTests {
    @Test("Planner chooses right-adjacent source region when available")
    func choosesRightAdjacentSourceRegion() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 1000, height: 700),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 100, height: 44),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
            geometry: geometry
        )

        guard case let .apply(plan) = decision else {
            Issue.record("Expected clone-stamp plan for supported format")
            return
        }

        #expect(plan.sourceRect.minX > plan.destinationRect.maxX)
        #expect(plan.sourceRect.minY == plan.destinationRect.minY)
        #expect(plan.sourceRect.width <= 4)
        #expect(plan.sourceRect.height == plan.destinationRect.height)
    }

    @Test("Planner falls back to below-source region when right side is unavailable")
    func fallsBackToBelowSourceRegion() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 102, height: 420),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 100, height: 44),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 0, y: 0, width: 102, height: 420),
            geometry: geometry
        )

        guard case let .apply(plan) = decision else {
            Issue.record("Expected clone-stamp plan when below-source fallback is available")
            return
        }

        #expect(plan.sourceRect.minY > plan.destinationRect.maxY)
        #expect(plan.sourceRect.height <= 4)
        #expect(plan.sourceRect.width == plan.destinationRect.width)
    }

    @Test("Window to content scaling maps and clamps destination ROI")
    func scalesAndClampsDestinationROI() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 1000, height: 500),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 200, height: 100),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 10, y: 20, width: 600, height: 200),
            geometry: geometry
        )

        guard case let .apply(plan) = decision else {
            Issue.record("Expected plan for scale/clamp verification")
            return
        }

        #expect(plan.destinationRect.minX == 10)
        #expect(plan.destinationRect.minY == 20)
        #expect(plan.destinationRect.width == 120)
        #expect(plan.destinationRect.height == 40)

        let oversizedGeometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 500, height: 250),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 2000, height: 1000),
            buttonsHiddenState: .unknown,
            source: .fallback
        )
        let clampedDecision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 140),
            geometry: oversizedGeometry
        )

        guard case let .apply(clampedPlan) = clampedDecision else {
            Issue.record("Expected plan for clamped destination verification")
            return
        }

        #expect(clampedPlan.destinationRect.minX == 0)
        #expect(clampedPlan.destinationRect.minY == 0)
        #expect(clampedPlan.destinationRect.maxX <= 300)
        #expect(clampedPlan.destinationRect.maxY <= 140)
    }

    @Test("Feather and blur stay within bounded visual range")
    func featherAndBlurAreBounded() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 1000, height: 700),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 160, height: 80),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_32BGRA,
            contentRect: CGRect(x: 0, y: 0, width: 2000, height: 1400),
            geometry: geometry
        )

        guard case let .apply(plan) = decision else {
            Issue.record("Expected plan for feather/blur bounds")
            return
        }

        #expect(plan.featherPixels >= 2)
        #expect(plan.featherPixels <= 3.4)
        #expect(plan.blurRadiusPixels >= 0.45)
        #expect(plan.blurRadiusPixels <= 1.1)
    }

    @Test("Unsupported pixel formats skip cleanly")
    func unsupportedFormatSkips() {
        let geometry = HostTrafficLightMaskGeometryResolver.ResolvedGeometry(
            windowFramePoints: CGRect(x: 0, y: 0, width: 1000, height: 700),
            clusterRectPoints: CGRect(x: 0, y: 0, width: 96, height: 44),
            buttonsHiddenState: .unknown,
            source: .fallback
        )

        let decision = HostTrafficLightCloneStampPlanner.makeDecision(
            pixelFormat: kCVPixelFormatType_422YpCbCr8,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
            geometry: geometry
        )

        guard case let .skip(reason) = decision else {
            Issue.record("Expected skip decision for unsupported pixel format")
            return
        }

        #expect(reason == .unsupportedPixelFormat)
    }
}
#endif
