//
//  CGVirtualDisplayBridgeColorValidationTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("CGVirtualDisplayBridge Color Validation")
struct CGVirtualDisplayBridgeColorValidationTests {
    @Test("Display P3 leaves named wide-gamut RGB aliases unresolved")
    func displayP3LeavesNamedWideGamutAliasUnresolved() throws {
        let observedColorSpace = try #require(CGColorSpace(name: CGColorSpace.itur_2020 as CFString))

        let validation = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observedColorSpace,
            expectedColorSpace: .displayP3
        )

        #expect(validation.coverageStatus == .unresolved)
        #expect(validation.observedName == (CGColorSpace.itur_2020 as String))
    }

    @Test("sRGB leaves named wide-gamut RGB aliases unresolved")
    func sRGBLeavesNamedWideGamutAliasUnresolved() throws {
        let observedColorSpace = try #require(CGColorSpace(name: CGColorSpace.itur_2020 as CFString))

        let validation = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observedColorSpace,
            expectedColorSpace: .sRGB
        )

        #expect(validation.coverageStatus == .unresolved)
        #expect(validation.observedName == (CGColorSpace.itur_2020 as String))
    }
}
#endif
