//
//  StreamContext+Sizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture sizing and queue limit calculations.
//

import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Update the current content rectangle (called per-frame from capture callback).
    func setContentRect(_ rect: CGRect) {
        currentContentRect = rect
    }

    func scaledOutputSize(for baseSize: CGSize) -> CGSize {
        let clampedScale = streamScale
        let width = StreamContext.alignedEvenPixel(baseSize.width * clampedScale)
        let height = StreamContext.alignedEvenPixel(baseSize.height * clampedScale)
        return CGSize(width: width, height: height)
    }

    func updateCaptureSizesIfNeeded(_ bufferSize: CGSize) {
        guard bufferSize.width > 0, bufferSize.height > 0 else { return }
        guard bufferSize != currentCaptureSize else { return }
        currentCaptureSize = bufferSize
        currentEncodedSize = bufferSize
        if streamScale > 0 { baseCaptureSize = CGSize(width: bufferSize.width / streamScale, height: bufferSize.height / streamScale) }
        updateQueueLimits()
    }

    func updateQueueLimits() {
        guard currentEncodedSize.width > 0, currentEncodedSize.height > 0 else { return }
        let pixelCount = Double(currentEncodedSize.width * currentEncodedSize.height)
        let frameRateFactor = currentFrameRate >= 120 ? 0.22 : 0.15
        let pixelBased = Int((pixelCount * frameRateFactor).rounded())
        let bitrateBased: Int
        if let bitrate = encoderConfig.bitrate, bitrate > 0 {
            let bytesPerSecond = Double(bitrate) / 8.0
            let windowSeconds = currentFrameRate >= 120 ? 0.12 : 0.14
            bitrateBased = Int((bytesPerSecond * windowSeconds).rounded())
        } else {
            bitrateBased = 0
        }
        let computed = max(pixelBased, bitrateBased)
        let clamped = max(minQueuedBytes, min(maxQueuedBytesCap, computed))
        maxQueuedBytes = clamped
        queuePressureBytes = max(minQueuedBytes, Int(Double(clamped) * 0.60))
    }
}
#endif
