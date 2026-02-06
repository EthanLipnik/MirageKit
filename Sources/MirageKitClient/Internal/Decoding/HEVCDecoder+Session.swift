//
//  HEVCDecoder+Session.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

extension HEVCDecoder {
    func createSession(formatDescription: CMFormatDescription) throws {
        do {
            try createSession(formatDescription: formatDescription, outputPixelFormat: outputPixelFormat)
        } catch {
            guard let fallback = fallbackOutputPixelFormat(for: outputPixelFormat) else { throw error }
            try createSession(formatDescription: formatDescription, outputPixelFormat: fallback)
            outputPixelFormat = fallback
        }
    }

    private func createSession(formatDescription: CMFormatDescription, outputPixelFormat: OSType) throws {
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            ] as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else { throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
    }

    private func fallbackOutputPixelFormat(for outputPixelFormat: OSType) -> OSType? {
        switch outputPixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            kCVPixelFormatType_32BGRA
        case kCVPixelFormatType_ARGB2101010LEPacked:
            kCVPixelFormatType_32BGRA
        default:
            nil
        }
    }
}
