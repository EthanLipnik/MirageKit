//
//  VideoDecoder+Handlers.swift
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
    func setCodec(_ newCodec: MirageVideoCodec, streamDimensions: (width: Int, height: Int)? = nil) {
        codec = newCodec
        proResStreamDimensions = streamDimensions
        MirageLogger.decoder("Decoder codec set to \(newCodec.rawValue)")
    }

    func setMaximizePowerEfficiencyEnabled(_ enabled: Bool) {
        guard maximizePowerEfficiencyEnabled != enabled else { return }
        maximizePowerEfficiencyEnabled = enabled

        guard let session = decompressionSession else {
            MirageLogger.decoder("Decoder power preference updated: maximizePowerEfficiency=\(enabled) (deferred)")
            return
        }

        let applied = applyMaximizePowerEfficiency(session)
        if !applied {
            MirageLogger.decoder(
                "Decoder power preference updated: maximizePowerEfficiency=\(enabled) (deferred to next session)"
            )
        }
    }

    func setMetalFXOutputOverride(_ enabled: Bool) {
        guard metalFXOutputOverrideEnabled != enabled else { return }
        metalFXOutputOverrideEnabled = enabled

        let desiredPixelFormat = preferredOutputPixelFormat(for: preferredOutputColorDepth)
        let formatChanged = outputPixelFormat != desiredPixelFormat
        outputPixelFormat = desiredPixelFormat

        guard formatChanged else {
            MirageLogger.decoder("MetalFX output override set to \(enabled) (no format change)")
            return
        }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            pendingOutputTelemetryGeneration = 0
            lastDecodedOutputPixelFormat = nil
            MirageLogger.decoder(
                "MetalFX output override set to \(enabled); invalidated active session for format change to \(Self.pixelFormatName(desiredPixelFormat))"
            )
        } else {
            MirageLogger.decoder(
                "MetalFX output override set to \(enabled); format will be \(Self.pixelFormatName(desiredPixelFormat))"
            )
        }
    }

    func setPreferredOutputColorDepth(_ colorDepth: MirageStreamColorDepth) {
        let desiredPixelFormat = preferredOutputPixelFormat(for: colorDepth)
        let formatChanged = outputPixelFormat != desiredPixelFormat
        preferredOutputColorDepth = colorDepth
        outputPixelFormat = desiredPixelFormat

        guard formatChanged else { return }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            pendingOutputTelemetryGeneration = 0
            lastDecodedOutputPixelFormat = nil
            MirageLogger.decoder(
                "Decoder preferred output color depth set to \(colorDepth.displayName); invalidated active session"
            )
        } else {
            MirageLogger.decoder("Decoder preferred output color depth set to \(colorDepth.displayName)")
        }
    }

    func setErrorThresholdHandler(_ handler: @escaping @Sendable () -> Void) {
        errorTracker = DecodeErrorTracker(
            maxErrors: maxConsecutiveErrors,
            onThresholdReached: handler,
            onRecovery: nil
        )
    }

    func setDimensionChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        onDimensionChange = handler
    }

    func getAverageDecodeTimeMs() -> Double {
        performanceTracker.averageMs()
    }

    func getTotalDecodeErrors() -> UInt64 {
        errorTracker?.totalErrorsSnapshot() ?? 0
    }

    func decodedOutputPixelFormatName() -> String? {
        let pixelFormat = lastDecodedOutputPixelFormat ?? outputPixelFormat
        return VideoDecoder.pixelFormatName(pixelFormat)
    }

    func prepareForDimensionChange(expectedWidth: Int? = nil, expectedHeight: Int? = nil) {
        awaitingDimensionChange = true
        dimensionChangeStartTime = CFAbsoluteTimeGetCurrent()
        if let w = expectedWidth, let h = expectedHeight { expectedDimensions = (w, h) } else {
            expectedDimensions = nil
        }
        MirageLogger.decoder("Dimension change expected - discarding P-frames until keyframe")
    }

    func clearPendingState() {
        if awaitingDimensionChange {
            MirageLogger.decoder("Clearing stuck awaitingDimensionChange state for recovery")
            awaitingDimensionChange = false
            expectedDimensions = nil
        }
        // Reset error tracking to give fresh keyframe a clean slate
        errorTracker?.clearForSessionReset()
    }
}
