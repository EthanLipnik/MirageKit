//
//  HEVCDecoderOutputFormatPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Coverage for decoder output-format fallback warning policy.
//

@testable import MirageKitClient
import MirageKit
import CoreVideo
import Testing

#if os(macOS)
@Suite("HEVC Decoder Output Format Policy")
struct HEVCDecoderOutputFormatPolicyTests {
    @Test("10-bit preferred with 10-bit output does not warn")
    func tenBitPreferredWithTenBitOutputDoesNotWarn() {
        let shouldWarn = HEVCDecoder.shouldWarnTenBitFallback(
            preferredBitDepth: .tenBit,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )

        #expect(!shouldWarn)
    }

    @Test("10-bit preferred with 8-bit output warns")
    func tenBitPreferredWithEightBitOutputWarns() {
        let shouldWarn = HEVCDecoder.shouldWarnTenBitFallback(
            preferredBitDepth: .tenBit,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        #expect(shouldWarn)
    }

    @Test("8-bit preferred never warns for fallback")
    func eightBitPreferredDoesNotWarn() {
        let shouldWarn = HEVCDecoder.shouldWarnTenBitFallback(
            preferredBitDepth: .eightBit,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        #expect(!shouldWarn)
    }
}
#endif
