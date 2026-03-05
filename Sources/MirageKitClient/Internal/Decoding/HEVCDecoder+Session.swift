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
        let requestedOutputPixelFormat = outputPixelFormat
        var activeOutputPixelFormat = requestedOutputPixelFormat

        do {
            try createSession(
                formatDescription: formatDescription,
                outputPixelFormat: requestedOutputPixelFormat
            )
        } catch {
            guard let fallback = fallbackOutputPixelFormat(for: requestedOutputPixelFormat) else { throw error }

            let requestedName = Self.pixelFormatName(requestedOutputPixelFormat)
            let fallbackName = Self.pixelFormatName(fallback)
            MirageLogger
                .decoder(
                    "Decoder session creation failed for \(requestedName) (\((error as NSError).code)); retrying with \(fallbackName)"
                )

            try createSession(
                formatDescription: formatDescription,
                outputPixelFormat: fallback
            )
            activeOutputPixelFormat = fallback
            outputPixelFormat = fallback
        }

        decompressionSessionGeneration &+= 1
        pendingOutputTelemetryGeneration = decompressionSessionGeneration

        let requestedName = Self.pixelFormatName(requestedOutputPixelFormat)
        let activeName = Self.pixelFormatName(activeOutputPixelFormat)
        MirageLogger
            .decoder(
                "Decoder session configured: preferred=\(preferredOutputBitDepth.displayName), requested=\(requestedName), active=\(activeName), generation=\(decompressionSessionGeneration)"
            )
        if Self.shouldWarnTenBitFallback(
            preferredBitDepth: preferredOutputBitDepth,
            actualOutputPixelFormat: activeOutputPixelFormat
        ) {
            MirageLogger
                .error(
                    .decoder,
                    "10-bit requested but session output format is \(activeName); continuing with fallback"
                )
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

    func recordDecodedOutputPixelFormat(_ pixelFormat: OSType, sessionGeneration: UInt64) {
        guard pendingOutputTelemetryGeneration == sessionGeneration else { return }
        pendingOutputTelemetryGeneration = 0

        let configuredName = Self.pixelFormatName(outputPixelFormat)
        let actualName = Self.pixelFormatName(pixelFormat)
        MirageLogger
            .decoder(
                "Decoder output format observed: actual=\(actualName), configured=\(configuredName), preferred=\(preferredOutputBitDepth.displayName), generation=\(sessionGeneration)"
            )
        if pixelFormat != outputPixelFormat {
            MirageLogger
                .decoder(
                    "VideoToolbox output format differs from configured destination for generation \(sessionGeneration)"
                )
        }
        if Self.shouldWarnTenBitFallback(
            preferredBitDepth: preferredOutputBitDepth,
            actualOutputPixelFormat: pixelFormat
        ) {
            MirageLogger
                .error(
                    .decoder,
                    "10-bit requested but decoder produced \(actualName); continuing with fallback"
                )
        }
    }
}
