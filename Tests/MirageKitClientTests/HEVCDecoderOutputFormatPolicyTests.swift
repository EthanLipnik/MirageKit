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
    @Test("Pro preferred with 10-bit output does not warn")
    func proPreferredWithTenBitOutputDoesNotWarn() {
        let shouldWarn = HEVCDecoder.shouldWarnOutputFormatFallback(
            preferredColorDepth: .pro,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )

        #expect(!shouldWarn)
    }

    @Test("Ultra preferred with 10-bit 4:4:4 output does not warn")
    func ultraPreferredWith444OutputDoesNotWarn() {
        let shouldWarn = HEVCDecoder.shouldWarnOutputFormatFallback(
            preferredColorDepth: .ultra,
            actualOutputPixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        )

        #expect(!shouldWarn)
        #expect(HEVCDecoder.pixelFormatName(kCVPixelFormatType_444YpCbCr10BiPlanarFullRange).contains("xf44"))
    }

    @Test("Ultra preferred with 10-bit 4:2:0 output warns")
    func ultraPreferredWith420TenBitOutputWarns() {
        let shouldWarn = HEVCDecoder.shouldWarnOutputFormatFallback(
            preferredColorDepth: .ultra,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )

        #expect(shouldWarn)
    }

    @Test("Pro preferred with 8-bit output warns")
    func proPreferredWithEightBitOutputWarns() {
        let shouldWarn = HEVCDecoder.shouldWarnOutputFormatFallback(
            preferredColorDepth: .pro,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        #expect(shouldWarn)
    }

    @Test("Standard preferred never warns for fallback")
    func standardPreferredDoesNotWarn() {
        let shouldWarn = HEVCDecoder.shouldWarnOutputFormatFallback(
            preferredColorDepth: .standard,
            actualOutputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        #expect(!shouldWarn)
    }

    @Test("Ultra requests xf44 output")
    func ultraRequests444Output() async {
        let decoder = HEVCDecoder()

        await decoder.setPreferredOutputColorDepth(.ultra)

        let outputPixelFormatName = await decoder.decodedOutputPixelFormatName()
        #expect(outputPixelFormatName == "xf44 (10-bit 4:4:4)")
    }

    @Test("Decoder fallback chain steps down from ultra to software-safe formats")
    func decoderFallbackChainStepsDownFromUltra() {
        #expect(
            HEVCDecoder.fallbackOutputPixelFormat(for: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        #expect(
            HEVCDecoder.fallbackOutputPixelFormat(for: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ==
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        #expect(
            HEVCDecoder.fallbackOutputPixelFormat(for: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ==
                kCVPixelFormatType_32BGRA
        )
    }
}
#endif
