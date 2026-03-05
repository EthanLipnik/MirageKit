//
//  VirtualDisplayColorValidationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Virtual Display Color Validation")
struct VirtualDisplayColorValidationTests {
    @Test("Display P3 canonical profile is classified as strict canonical")
    func displayP3StrictValidationAcceptsCanonicalProfile() {
        let observed = CGColorSpace(name: CGColorSpace.displayP3 as CFString)
        #expect(observed != nil)
        guard let observed else { return }

        let result = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observed,
            expectedColorSpace: .displayP3
        )
        #expect(result.coverageStatus == .strictCanonical)
    }

    @Test("Unnamed RGB profile is classified as Display P3 equivalent")
    func unnamedRGBClassifiesAsEquivalent() {
        guard let observed = makeUnnamedWideGamutRGB() else {
            Issue.record("Failed to construct unnamed wide-gamut test color space")
            return
        }

        #expect(observed.name == nil)
        #expect(observed.model == .rgb)

        let result = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observed,
            expectedColorSpace: .displayP3
        )
        #expect(result.coverageStatus == .wideGamutEquivalent)
    }

    @Test("Rec.2020 does not classify as Display P3 equivalent")
    func displayP3ValidationRejectsRec2020AsEquivalent() {
        let observed = CGColorSpace(name: CGColorSpace.itur_2020 as CFString)
        #expect(observed != nil)
        guard let observed else { return }

        let result = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observed,
            expectedColorSpace: .displayP3
        )
        #expect(result.coverageStatus == .unresolved)
        #expect(result.observedName != nil)
    }

    @Test("sRGB under Display P3 expectation is classified as fallback")
    func displayP3ValidationClassifiesSRGBFallback() {
        let observed = CGColorSpace(name: CGColorSpace.sRGB as CFString)
        #expect(observed != nil)
        guard let observed else { return }

        let result = CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observed,
            expectedColorSpace: .displayP3
        )
        #expect(result.coverageStatus == .sRGBFallback)
    }

    private func makeUnnamedWideGamutRGB() -> CGColorSpace? {
        var whitePoint: [CGFloat] = [0.95047, 1.0, 1.08883]
        var blackPoint: [CGFloat] = [0, 0, 0]
        var gamma: [CGFloat] = [2.2, 2.2, 2.2]
        var matrix: [CGFloat] = [
            0.48657095, 0.26566769, 0.19821729,
            0.22897456, 0.69173852, 0.07928691,
            0.00000000, 0.04511338, 1.04394437,
        ]
        return whitePoint.withUnsafeBufferPointer { whitePointPtr in
            blackPoint.withUnsafeBufferPointer { blackPointPtr in
                gamma.withUnsafeBufferPointer { gammaPtr in
                    matrix.withUnsafeBufferPointer { matrixPtr in
                        guard let whitePoint = whitePointPtr.baseAddress,
                              let blackPoint = blackPointPtr.baseAddress,
                              let gamma = gammaPtr.baseAddress,
                              let matrix = matrixPtr.baseAddress else {
                            return nil
                        }
                        return CGColorSpace(
                            calibratedRGBWhitePoint: whitePoint,
                            blackPoint: blackPoint,
                            gamma: gamma,
                            matrix: matrix
                        )
                    }
                }
            }
        }
    }
}
#endif
