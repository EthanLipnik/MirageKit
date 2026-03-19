//
//  VideoDecoder+Session.swift
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

extension VideoDecoder {
    func createSession(formatDescription: CMFormatDescription) throws {
        let requestedOutputPixelFormat = outputPixelFormat
        var activeOutputPixelFormat = requestedOutputPixelFormat
        var candidateOutputPixelFormat = requestedOutputPixelFormat

        while true {
            do {
                try createSession(
                    formatDescription: formatDescription,
                    outputPixelFormat: candidateOutputPixelFormat
                )
                activeOutputPixelFormat = candidateOutputPixelFormat
                break
            } catch {
                guard let fallback = Self.fallbackOutputPixelFormat(for: candidateOutputPixelFormat) else { throw error }

                let requestedName = Self.pixelFormatName(candidateOutputPixelFormat)
                let fallbackName = Self.pixelFormatName(fallback)
                MirageLogger
                    .decoder(
                        "Decoder session creation failed for \(requestedName) (\((error as NSError).code)); retrying with \(fallbackName)"
                    )
                candidateOutputPixelFormat = fallback
            }
        }

        outputPixelFormat = activeOutputPixelFormat

        decompressionSessionGeneration &+= 1
        pendingOutputTelemetryGeneration = decompressionSessionGeneration
        lastDecodedOutputPixelFormat = nil

        let requestedName = Self.pixelFormatName(requestedOutputPixelFormat)
        let activeName = Self.pixelFormatName(activeOutputPixelFormat)
        MirageLogger
            .decoder(
                "Decoder session configured: preferred=\(preferredOutputColorDepth.displayName), requested=\(requestedName), active=\(activeName), generation=\(decompressionSessionGeneration)"
            )
        if Self.shouldWarnOutputFormatFallback(
            preferredColorDepth: preferredOutputColorDepth,
            actualOutputPixelFormat: activeOutputPixelFormat
        ),
            let requirementName = Self.outputFormatRequirementName(for: preferredOutputColorDepth) {
            MirageLogger
                .error(
                    .decoder,
                    "\(preferredOutputColorDepth.displayName) requested but session output format is \(activeName); \(requirementName) decode unavailable, continuing with fallback"
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

        decoderHardwareStatusRefreshAttempts = 0
        usingHardwareDecoder = nil
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        _ = applyMaximizePowerEfficiency(session)
        logHardwareDecoderStatus(session, reason: "session_create")
        decompressionSession = session
    }

    nonisolated static func fallbackOutputPixelFormat(for outputPixelFormat: OSType) -> OSType? {
        switch outputPixelFormat {
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
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

    func invalidateSessionIfCurrent(afterCallbackFailure reason: String, sessionGeneration: UInt64) {
        guard sessionGeneration == decompressionSessionGeneration else { return }
        guard let session = decompressionSession else { return }

        VTDecompressionSessionInvalidate(session)
        decompressionSession = nil
        pendingOutputTelemetryGeneration = 0
        lastDecodedOutputPixelFormat = nil
        usingHardwareDecoder = nil
        decoderHardwareStatusRefreshAttempts = 0

        MirageLogger.decoder(
            "Decoder session invalidated after callback failure (\(reason), generation \(sessionGeneration))"
        )
    }

    func recordDecodedOutputPixelFormat(_ pixelFormat: OSType, sessionGeneration: UInt64) {
        lastDecodedOutputPixelFormat = pixelFormat
        guard pendingOutputTelemetryGeneration == sessionGeneration else { return }
        pendingOutputTelemetryGeneration = 0
        refreshHardwareDecoderStatusIfNeeded(reason: "first_output_generation_\(sessionGeneration)")

        let configuredName = Self.pixelFormatName(outputPixelFormat)
        let actualName = Self.pixelFormatName(pixelFormat)
        MirageLogger
            .decoder(
                "Decoder output format observed: actual=\(actualName), configured=\(configuredName), preferred=\(preferredOutputColorDepth.displayName), generation=\(sessionGeneration)"
            )
        if pixelFormat != outputPixelFormat {
            MirageLogger
                .decoder(
                    "VideoToolbox output format differs from configured destination for generation \(sessionGeneration)"
                )
        }
        if Self.shouldWarnOutputFormatFallback(
            preferredColorDepth: preferredOutputColorDepth,
            actualOutputPixelFormat: pixelFormat
        ),
            let requirementName = Self.outputFormatRequirementName(for: preferredOutputColorDepth) {
            MirageLogger
                .error(
                    .decoder,
                    "\(preferredOutputColorDepth.displayName) requested but decoder produced \(actualName); \(requirementName) decode unavailable, continuing with fallback"
                )
        }
    }

    private func refreshHardwareDecoderStatusIfNeeded(reason: String) {
        guard decoderHardwareStatusRefreshAttempts < maxDecoderHardwareStatusRefreshAttempts else { return }
        guard usingHardwareDecoder == nil else { return }
        guard let session = decompressionSession else { return }
        logHardwareDecoderStatus(session, reason: reason)
    }

    @discardableResult
    func applyMaximizePowerEfficiency(_ session: VTDecompressionSession) -> Bool {
        let value: CFTypeRef = maximizePowerEfficiencyEnabled ? kCFBooleanTrue : kCFBooleanFalse
        let status = VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_MaximizePowerEfficiency,
            value: value
        )
        guard status == noErr else {
            MirageLogger.error(
                .decoder,
                "Failed to set decoder power preference maximizePowerEfficiency=\(maximizePowerEfficiencyEnabled): \(status)"
            )
            return false
        }
        MirageLogger.decoder(
            "Decoder power preference applied: maximizePowerEfficiency=\(maximizePowerEfficiencyEnabled)"
        )
        return true
    }

    private func logHardwareDecoderStatus(_ session: VTDecompressionSession, reason: String) {
        decoderHardwareStatusRefreshAttempts += 1
        usingHardwareDecoder = nil

        var hardwareProperty: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hardwareProperty
        )
        if hardwareStatus == noErr,
           let value = hardwareProperty?.takeRetainedValue(),
           let boolValue = value as? Bool {
            usingHardwareDecoder = boolValue
        }

        let usingHardwareText: String = if let usingHardwareDecoder {
            String(usingHardwareDecoder)
        } else {
            "unknown(status=\(hardwareStatus))"
        }
        let healthText: String = if usingHardwareDecoder == true {
            "active"
        } else if usingHardwareDecoder == false {
            "software_fallback"
        } else {
            "unknown"
        }

        MirageLogger.decoder(
            "event=hardware_decoder_status reason=\(reason) usingHardware=\(usingHardwareText) " +
                "status=\(healthText) enabledBySpec=true"
        )
    }
}
