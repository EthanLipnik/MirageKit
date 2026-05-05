//
//  SharedVirtualDisplayValidationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Shared Virtual Display Validation")
struct SharedVirtualDisplayValidationTests {
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
}
#endif
