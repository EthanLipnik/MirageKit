//
//  StreamContextDisplayP3ValidationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("StreamContext Display P3 Validation")
struct StreamContextDisplayP3ValidationTests {
    @Test("Strict canonical coverage passes when capture and encoder validations pass")
    func strictCanonicalPasses() {
        let result = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .strictCanonical,
            captureIsTenBitP010: true,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: true
        )
        #expect(result == true)
    }

    @Test("Wide-gamut equivalent coverage passes when capture and encoder validations pass")
    func wideGamutEquivalentPasses() {
        let result = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .wideGamutEquivalent,
            captureIsTenBitP010: true,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: true
        )
        #expect(result == true)
    }

    @Test("sRGB fallback and unresolved coverage fail validation")
    func fallbackCoverageFails() {
        let sRGBFallbackResult = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .sRGBFallback,
            captureIsTenBitP010: true,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: true
        )
        let unresolvedResult = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .unresolved,
            captureIsTenBitP010: true,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: true
        )
        #expect(sRGBFallbackResult == false)
        #expect(unresolvedResult == false)
    }

    @Test("Missing capture or encoder validation data remains unresolved")
    func missingValidationDataIsUnresolved() {
        let missingCaptureResult = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .wideGamutEquivalent,
            captureIsTenBitP010: nil,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: true
        )
        let missingEncoderResult = StreamContext.measuredTenBitDisplayP3Validation(
            coverageStatus: .wideGamutEquivalent,
            captureIsTenBitP010: true,
            captureIsDisplayP3: true,
            encoderTenBitDisplayP3Validated: nil
        )
        #expect(missingCaptureResult == nil)
        #expect(missingEncoderResult == nil)
    }
}
#endif
