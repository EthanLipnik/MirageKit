//
//  MirageColorAttachments.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/23/26.
//
//  Shared color attachment enforcement for encode and decode pipelines.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

package enum MirageColorAttachments {
    struct VideoColorAttachments {
        let colorPrimaries: CFString
        let transferFunction: CFString
        let yCbCrMatrix: CFString
        let cgColorSpaceName: CFString
    }

    static func expectedAttachments(for colorSpace: MirageColorSpace) -> VideoColorAttachments {
        switch colorSpace {
        case .displayP3:
            VideoColorAttachments(
                colorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
                transferFunction: kCVImageBufferTransferFunction_sRGB,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpaceName: CGColorSpace.displayP3
            )
        case .sRGB:
            VideoColorAttachments(
                colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transferFunction: kCVImageBufferTransferFunction_sRGB,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpaceName: CGColorSpace.sRGB
            )
        }
    }

    /// Enforce color attachments on a pixel buffer, setting only when the existing value differs.
    package static func enforceOnPixelBuffer(_ pixelBuffer: CVPixelBuffer, colorSpace: MirageColorSpace) {
        let expected = expectedAttachments(for: colorSpace)
        setAttachmentIfNeeded(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: expected.colorPrimaries)
        setAttachmentIfNeeded(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: expected.transferFunction)
        setAttachmentIfNeeded(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: expected.yCbCrMatrix)
        if let cgColorSpace = CGColorSpace(name: expected.cgColorSpaceName) {
            setAttachmentIfNeeded(pixelBuffer, key: kCVImageBufferCGColorSpaceKey, value: cgColorSpace)
        }
    }

    /// Build a CFDictionary of color space extensions for CMVideoFormatDescription creation.
    package static func formatDescriptionExtensions(for colorSpace: MirageColorSpace) -> CFDictionary {
        let expected = expectedAttachments(for: colorSpace)
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: expected.colorPrimaries,
            kCMFormatDescriptionExtension_TransferFunction: expected.transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: expected.yCbCrMatrix,
        ]
        return extensions as CFDictionary
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
