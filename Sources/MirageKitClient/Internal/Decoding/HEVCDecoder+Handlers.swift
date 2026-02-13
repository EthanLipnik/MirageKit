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
