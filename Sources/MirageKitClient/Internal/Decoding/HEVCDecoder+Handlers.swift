//
//  HEVCDecoder+Handlers.swift
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

    func setPreferredOutputBitDepth(_ bitDepth: MirageVideoBitDepth) {
        let desiredPixelFormat = preferredOutputPixelFormat(for: bitDepth)
        let formatChanged = outputPixelFormat != desiredPixelFormat
        preferredOutputBitDepth = bitDepth
        outputPixelFormat = desiredPixelFormat

        guard formatChanged else { return }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            pendingOutputTelemetryGeneration = 0
            MirageLogger.decoder(
                "Decoder preferred output bit depth set to \(bitDepth.displayName); invalidated active session"
            )
        } else {
            MirageLogger.decoder("Decoder preferred output bit depth set to \(bitDepth.displayName)")
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
