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
