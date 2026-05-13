//
//  StreamContext+ColorAttachments.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/19/26.
//
//  Capture color attachment enforcement before encode.
//

import CoreGraphics
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    struct CaptureColorAttachments {
        let colorPrimaries: CFString
        let transferFunction: CFString
        let yCbCrMatrix: CFString
        let cgColorSpaceName: CFString
    }

    func enforceCaptureColorAttachments(on pixelBuffer: CVPixelBuffer) {
        Self.enforceCaptureColorAttachments(
            on: pixelBuffer,
            colorSpace: encoderConfig.colorSpace
        )
    }

    static func enforceCaptureColorAttachments(
        on pixelBuffer: CVPixelBuffer,
        colorSpace: MirageColorSpace
    ) {
        let expected = expectedCaptureColorAttachments(for: colorSpace)
        MirageCVBufferAttachments.setIfNeeded(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: expected.colorPrimaries)
        MirageCVBufferAttachments.setIfNeeded(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: expected.transferFunction)
        MirageCVBufferAttachments.setIfNeeded(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: expected.yCbCrMatrix)
        if let colorSpace = CGColorSpace(name: expected.cgColorSpaceName) {
            MirageCVBufferAttachments.setIfNeeded(pixelBuffer, key: kCVImageBufferCGColorSpaceKey, value: colorSpace)
        }
    }

    static func expectedCaptureColorAttachments(for colorSpace: MirageColorSpace) -> CaptureColorAttachments {
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
}
#endif
