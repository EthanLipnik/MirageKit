//
//  DisplayStartupFrameSeeder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/10/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import VideoToolbox

enum DisplayStartupFrameSeeder {
    static func makeCapturedFrame(
        from image: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        pixelFormatType: OSType,
        colorSpace: MirageColorSpace,
        frameRate: Int
    ) -> CapturedFrame? {
        let width = max(1, targetWidth)
        let height = max(1, targetHeight)
        guard let sourceBuffer = makeBGRAPixelBuffer(
            from: image,
            targetWidth: width,
            targetHeight: height,
            colorSpace: colorSpace
        ) else {
            return nil
        }

        let captureBuffer: CVPixelBuffer
        if pixelFormatType == kCVPixelFormatType_32BGRA {
            captureBuffer = sourceBuffer
        } else {
            guard let convertedBuffer = makePixelBuffer(
                width: width,
                height: height,
                pixelFormatType: pixelFormatType
            ) else {
                return nil
            }

            guard transferImage(from: sourceBuffer, to: convertedBuffer) else {
                return nil
            }
            captureBuffer = convertedBuffer
        }

        enforceCaptureColorAttachments(on: captureBuffer, colorSpace: colorSpace)

        let timescale = CMTimeScale(max(1, frameRate))
        return CapturedFrame(
            pixelBuffer: captureBuffer,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: timescale),
            captureTime: CFAbsoluteTimeGetCurrent(),
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                dirtyPercentage: 100,
                isIdleFrame: false
            )
        )
    }

    private static func makeBGRAPixelBuffer(
        from image: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        colorSpace: MirageColorSpace
    ) -> CVPixelBuffer? {
        guard let pixelBuffer = makePixelBuffer(
            width: targetWidth,
            height: targetHeight,
            pixelFormatType: kCVPixelFormatType_32BGRA
        ) else {
            return nil
        }

        let attachments = expectedColorAttachments(for: colorSpace)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cgColorSpace = CGColorSpace(name: attachments.cgColorSpaceName) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cgColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        enforceCaptureColorAttachments(on: pixelBuffer, colorSpace: colorSpace)
        return pixelBuffer
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormatType: OSType
    ) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormatType,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func transferImage(from sourceBuffer: CVPixelBuffer, to destinationBuffer: CVPixelBuffer) -> Bool {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        ) == noErr,
              let session else {
            return false
        }

        defer {
            VTPixelTransferSessionInvalidate(session)
        }

        return VTPixelTransferSessionTransferImage(
            session,
            from: sourceBuffer,
            to: destinationBuffer
        ) == noErr
    }

    private struct CaptureColorAttachments {
        let colorPrimaries: CFString
        let transferFunction: CFString
        let yCbCrMatrix: CFString
        let cgColorSpaceName: CFString
    }

    private static func expectedColorAttachments(for colorSpace: MirageColorSpace) -> CaptureColorAttachments {
        switch colorSpace {
        case .displayP3:
            return CaptureColorAttachments(
                colorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
                transferFunction: kCVImageBufferTransferFunction_sRGB,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpaceName: CGColorSpace.displayP3
            )
        case .sRGB:
            return CaptureColorAttachments(
                colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_sRGB,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpaceName: CGColorSpace.sRGB
            )
        }
    }

    private static func enforceCaptureColorAttachments(
        on pixelBuffer: CVPixelBuffer,
        colorSpace: MirageColorSpace
    ) {
        let expected = expectedColorAttachments(for: colorSpace)
        setAttachmentIfNeeded(
            pixelBuffer,
            key: kCVImageBufferColorPrimariesKey,
            value: expected.colorPrimaries
        )
        setAttachmentIfNeeded(
            pixelBuffer,
            key: kCVImageBufferTransferFunctionKey,
            value: expected.transferFunction
        )
        setAttachmentIfNeeded(
            pixelBuffer,
            key: kCVImageBufferYCbCrMatrixKey,
            value: expected.yCbCrMatrix
        )
        if let cgColorSpace = CGColorSpace(name: expected.cgColorSpaceName) {
            setAttachmentIfNeeded(
                pixelBuffer,
                key: kCVImageBufferCGColorSpaceKey,
                value: cgColorSpace
            )
        }
    }

    private static func setAttachmentIfNeeded(
        _ buffer: CVBuffer,
        key: CFString,
        value: CFTypeRef
    ) {
        if let existing = CVBufferCopyAttachment(buffer, key, nil), CFEqual(existing, value) {
            return
        }
        CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
}
#endif
