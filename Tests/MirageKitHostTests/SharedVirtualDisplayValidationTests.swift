//
//  SharedVirtualDisplayValidationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

#if os(macOS)
@Suite("Shared Virtual Display Validation")
struct SharedVirtualDisplayValidationTests {
    @Test("Retina 1x fallback acceptance is gated to macOS 27")
    func retinaOneXFallbackAcceptanceIsGatedToMacOS27() {
        #expect(
            CGVirtualDisplayBridge.allowsRetinaOneXFallback(
                on: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            )
        )
        #expect(
            !CGVirtualDisplayBridge.allowsRetinaOneXFallback(
                on: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
            )
        )
        #expect(
            !CGVirtualDisplayBridge.allowsRetinaOneXFallback(
                on: OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)
            )
        )
    }

    @Test("Display validation accepts exact 1x display when CoreGraphics refresh is unavailable")
    func displayValidationAcceptsExactOneXDisplayWhenCoreGraphicsRefreshIsUnavailable() {
        let expected = CGSize(width: 1280, height: 640)
        let acceptance = SharedVirtualDisplayManager.displayModeValidationAcceptance(
            snapshot: SharedVirtualDisplayManager.DisplayModeValidationSnapshot(
                boundsSize: expected,
                screenCaptureSize: expected,
                modeLogicalSize: .zero,
                modePixelSize: .zero,
                modeRefreshRate: nil
            ),
            expectedLogicalResolution: expected,
            expectedPixelResolution: expected,
            expectedRefreshRate: 30
        )

        #expect(acceptance == .missingCoreGraphicsRefreshOneX)
    }

    @Test("Display validation accepts Retina display when CoreGraphics mode is unavailable")
    func displayValidationAcceptsRetinaDisplayWhenCoreGraphicsModeIsUnavailable() {
        let expectedLogical = CGSize(width: 1728, height: 890)
        let expectedPixel = CGSize(width: 3456, height: 1776)
        let acceptance = SharedVirtualDisplayManager.displayModeValidationAcceptance(
            snapshot: SharedVirtualDisplayManager.DisplayModeValidationSnapshot(
                boundsSize: expectedLogical,
                screenCaptureSize: expectedPixel,
                modeLogicalSize: .zero,
                modePixelSize: .zero,
                modeRefreshRate: nil
            ),
            expectedLogicalResolution: expectedLogical,
            expectedPixelResolution: expectedPixel,
            expectedRefreshRate: 30
        )

        #expect(acceptance == .missingCoreGraphicsMode)
    }

    @Test("Display validation rejects wrong refresh when CoreGraphics reports a mode")
    func displayValidationRejectsWrongRefreshWhenCoreGraphicsReportsMode() {
        let expected = CGSize(width: 1280, height: 640)
        let acceptance = SharedVirtualDisplayManager.displayModeValidationAcceptance(
            snapshot: SharedVirtualDisplayManager.DisplayModeValidationSnapshot(
                boundsSize: expected,
                screenCaptureSize: expected,
                modeLogicalSize: expected,
                modePixelSize: expected,
                modeRefreshRate: 60
            ),
            expectedLogicalResolution: expected,
            expectedPixelResolution: expected,
            expectedRefreshRate: 30
        )

        #expect(acceptance == nil)
    }

    @Test("Post-ready enforcement is skipped when observed mode matches")
    func postReadyEnforcementIsSkippedWhenObservedModeMatches() {
        let observed = SharedVirtualDisplayManager.ObservedDisplayMode(
            logicalResolution: CGSize(width: 1280, height: 720),
            pixelResolution: CGSize(width: 2560, height: 1440),
            refreshRate: 60
        )

        #expect(
            !SharedVirtualDisplayManager.needsPostReadyModeEnforcement(
                observedMode: observed,
                expectedPixelResolution: CGSize(width: 2560, height: 1440),
                expectedRefreshRate: 60
            )
        )
    }

    @Test("Post-ready enforcement runs when observed mode differs")
    func postReadyEnforcementRunsWhenObservedModeDiffers() {
        let observed = SharedVirtualDisplayManager.ObservedDisplayMode(
            logicalResolution: CGSize(width: 1280, height: 720),
            pixelResolution: CGSize(width: 1920, height: 1080),
            refreshRate: 30
        )

        #expect(
            SharedVirtualDisplayManager.needsPostReadyModeEnforcement(
                observedMode: observed,
                expectedPixelResolution: CGSize(width: 2560, height: 1440),
                expectedRefreshRate: 60
            )
        )
    }

    @Test("Retina requests accept stable 1x fallback when pixel resolution is preserved")
    func retinaRequestsAcceptStableOneXFallbackWhenPixelResolutionIsPreserved() {
        #expect(
            CGVirtualDisplayBridge.isAcceptableOneXFallbackForRetinaRequest(
                requestedLogical: CGSize(width: 1072, height: 576),
                requestedPixel: CGSize(width: 2144, height: 1152),
                observedLogical: CGSize(width: 2144, height: 1152),
                observedPixel: CGSize(width: 2144, height: 1152),
                observedBounds: CGRect(x: 0, y: 0, width: 2144, height: 1152),
                observedPixelDimensions: CGSize(width: 2144, height: 1152),
                isOnline: true
            )
        )
    }

    @Test("Retina requests reject 1x fallback when the activated pixel mode is wrong")
    func retinaRequestsRejectOneXFallbackWhenActivatedPixelModeIsWrong() {
        #expect(
            !CGVirtualDisplayBridge.isAcceptableOneXFallbackForRetinaRequest(
                requestedLogical: CGSize(width: 1072, height: 576),
                requestedPixel: CGSize(width: 2144, height: 1152),
                observedLogical: CGSize(width: 1920, height: 1080),
                observedPixel: CGSize(width: 1920, height: 1080),
                observedBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                observedPixelDimensions: CGSize(width: 1920, height: 1080),
                isOnline: true
            )
        )
    }

    @Test("Retina collapse detector recognizes logical-sized 1x activation")
    func retinaCollapseDetectorRecognizesLogicalSizedOneXActivation() {
        #expect(
            CGVirtualDisplayBridge.isCollapsedOneXModeForRetinaRequest(
                requestedLogical: CGSize(width: 1600, height: 1200),
                requestedPixel: CGSize(width: 3200, height: 2400),
                observedLogical: CGSize(width: 1600, height: 1200),
                observedPixel: CGSize(width: 1600, height: 1200),
                observedBounds: CGRect(x: 0, y: 0, width: 1600, height: 1200),
                observedPixelDimensions: CGSize(width: 1600, height: 1200),
                isOnline: true
            )
        )
    }

    @Test("Retina collapse detector works when CoreGraphics mode is unavailable")
    func retinaCollapseDetectorWorksWhenCoreGraphicsModeIsUnavailable() {
        #expect(
            CGVirtualDisplayBridge.isCollapsedOneXModeForRetinaRequest(
                requestedLogical: CGSize(width: 1600, height: 1200),
                requestedPixel: CGSize(width: 3200, height: 2400),
                observedLogical: .zero,
                observedPixel: .zero,
                observedBounds: CGRect(x: 0, y: 0, width: 1600, height: 1200),
                observedPixelDimensions: CGSize(width: 1600, height: 1200),
                isOnline: true
            )
        )
    }
}
#endif
