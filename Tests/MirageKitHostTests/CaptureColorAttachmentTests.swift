//
//  CaptureColorAttachmentTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/19/26.
//
//  Coverage for host capture color attachment enforcement.
//

@testable import MirageKitHost
import CoreVideo
import MirageKit
import Testing

#if os(macOS)
@Suite("Capture Color Attachments")
struct CaptureColorAttachmentTests {
    @Test("Display P3 stream enforces P3 + sRGB + 709 tags")
    func displayP3Attachments() async throws {
        let buffer = try #require(makePixelBuffer(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange))

        StreamContext.enforceCaptureColorAttachments(on: buffer, colorSpace: .displayP3)

        let primaries = attachmentString(buffer, key: kCVImageBufferColorPrimariesKey)
        let transfer = attachmentString(buffer, key: kCVImageBufferTransferFunctionKey)
        let matrix = attachmentString(buffer, key: kCVImageBufferYCbCrMatrixKey)

        #expect(primaries == (kCVImageBufferColorPrimaries_P3_D65 as String))
        #expect(transfer == (kCVImageBufferTransferFunction_sRGB as String))
        #expect(matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
    }

    @Test("sRGB stream enforces 709 + sRGB + 709 tags")
    func srgbAttachments() async throws {
        let buffer = try #require(makePixelBuffer(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))

        StreamContext.enforceCaptureColorAttachments(on: buffer, colorSpace: .sRGB)

        let primaries = attachmentString(buffer, key: kCVImageBufferColorPrimariesKey)
        let transfer = attachmentString(buffer, key: kCVImageBufferTransferFunctionKey)
        let matrix = attachmentString(buffer, key: kCVImageBufferYCbCrMatrixKey)

        #expect(primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String))
        #expect(transfer == (kCVImageBufferTransferFunction_sRGB as String))
        #expect(matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
    }

    private func makePixelBuffer(pixelFormat: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func attachmentString(_ buffer: CVBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }
}
#endif
