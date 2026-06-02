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
/// Actor-local stream sizing state captured before a resize so failures can restore the pipeline.
struct StreamResizeRollbackSnapshot: Sendable {
    /// Source capture size before the resize attempt.
    let baseCaptureSize: CGSize

    /// Encoder output size before the resize attempt.
    let currentEncodedSize: CGSize

    /// Capture buffer size before the resize attempt.
    let currentCaptureSize: CGSize

    /// Pixel format active before the resize attempt.
    let activePixelFormat: MiragePixelFormat

    /// Last compositor frame observed for the streamed window.
    let lastWindowFrame: CGRect

    /// Effective stream scale in use before the resize attempt.
    let streamScale: CGFloat

    /// User-requested stream scale before resize clamping or fallback.
    let requestedStreamScale: CGFloat

    /// Capture mode active before the resize attempt.
    let captureMode: StreamContext.CaptureMode

    /// Dimension token clients use to reject frames from stale encoder sizes.
    let dimensionToken: UInt16

    /// Content rect reported by ScreenCaptureKit before the resize attempt.
    let currentContentRect: CGRect

    /// Display-capture crop rect before the resize attempt.
    let virtualDisplayCaptureSourceRect: CGRect

    /// Display-space presentation rect before the resize attempt.
    let virtualDisplayCapturePresentationRect: CGRect
}

extension StreamContext {
    /// Update the current content rectangle (called per-frame from capture callback).
    func setContentRect(_ rect: CGRect) {
        currentContentRect = rect
    }

    func makeResizeRollbackSnapshot() -> StreamResizeRollbackSnapshot {
        StreamResizeRollbackSnapshot(
            baseCaptureSize: baseCaptureSize,
            currentEncodedSize: currentEncodedSize,
            currentCaptureSize: currentCaptureSize,
            activePixelFormat: activePixelFormat,
            lastWindowFrame: lastWindowFrame,
            streamScale: streamScale,
            requestedStreamScale: requestedStreamScale,
            captureMode: captureMode,
            dimensionToken: dimensionToken,
            currentContentRect: currentContentRect,
            virtualDisplayCaptureSourceRect: virtualDisplayCaptureSourceRect,
            virtualDisplayCapturePresentationRect: virtualDisplayCapturePresentationRect
        )
    }

    func restoreResizeRollbackSnapshot(
        _ snapshot: StreamResizeRollbackSnapshot,
        restoredWindowFrame: CGRect? = nil
    ) {
        baseCaptureSize = snapshot.baseCaptureSize
        currentEncodedSize = snapshot.currentEncodedSize
        currentCaptureSize = snapshot.currentCaptureSize
        activePixelFormat = snapshot.activePixelFormat
        lastWindowFrame = restoredWindowFrame ?? snapshot.lastWindowFrame
        streamScale = snapshot.streamScale
        requestedStreamScale = snapshot.requestedStreamScale
        captureMode = snapshot.captureMode
        dimensionToken = snapshot.dimensionToken
        currentContentRect = snapshot.currentContentRect
        virtualDisplayCaptureSourceRect = snapshot.virtualDisplayCaptureSourceRect
        virtualDisplayCapturePresentationRect = snapshot.virtualDisplayCapturePresentationRect
        updateQueueLimits()
    }

    func rollbackResizeFailure(
        _ snapshot: StreamResizeRollbackSnapshot,
        logLabel: String,
        restoredWindowFrame: CGRect? = nil
    )
    async throws {
        let effectiveWindowFrame = restoredWindowFrame ?? snapshot.lastWindowFrame
        let captureSize = snapshot.currentCaptureSize == .zero
            ? snapshot.currentEncodedSize
            : snapshot.currentCaptureSize
        let encodedSize = snapshot.currentEncodedSize == .zero
            ? captureSize
            : snapshot.currentEncodedSize

        restoreResizeRollbackSnapshot(snapshot, restoredWindowFrame: effectiveWindowFrame)
        frameInbox.discardAll()
        await packetSender?.bumpGeneration(reason: "\(logLabel) rollback")
        resetPipelineStateForReconfiguration(reason: "\(logLabel) rollback")

        if let captureEngine {
            switch snapshot.captureMode {
            case .display:
                let width = Int(captureSize.width)
                let height = Int(captureSize.height)
                if width > 0, height > 0 {
                    try await captureEngine.updateResolution(width: width, height: height)
                }
            case .window:
                if !effectiveWindowFrame.isEmpty {
                    try await captureEngine.updateDimensions(
                        windowFrame: effectiveWindowFrame,
                        outputScale: snapshot.streamScale
                    )
                }
            }
        }

        if let encoder {
            let width = Int(encodedSize.width)
            let height = Int(encodedSize.height)
            if width > 0, height > 0 {
                try await encoder.updateDimensions(width: width, height: height)
            }
        }

        updateQueueLimits()
        if encodedSize != .zero {
            await applyDerivedQuality(for: encodedSize, logLabel: "\(logLabel) rollback")
        }
        await refreshCaptureCadence()
        await encoder?.forceKeyframe()
        MirageLogger.stream(
            "\(logLabel) rolled back to \(Int(encodedSize.width))x\(Int(encodedSize.height))"
        )
    }

    func scaledOutputSize(for baseSize: CGSize) -> CGSize {
        let effectiveEncoderMaxWidth = disableResolutionCap
            ? nil
            : encoderMaxWidth ?? Int(Self.maxEncodedWidth)
        let effectiveEncoderMaxHeight = disableResolutionCap
            ? nil
            : encoderMaxHeight ?? Int(Self.maxEncodedHeight)
        return MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: baseSize,
            requestedStreamScale: streamScale,
            encoderMaxWidth: effectiveEncoderMaxWidth,
            encoderMaxHeight: effectiveEncoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        ).encodedPixelSize
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
        let frameRateFactor: Double = currentFrameRate >= 120 ? 0.22 : 0.15
        let pixelBased = Int((pixelCount * frameRateFactor).rounded())
        let bitrateBased: Int
        if let bitrate = encoderConfig.bitrate, bitrate > 0 {
            let bytesPerSecond = Double(bitrate) / 8.0
            let windowSeconds: Double = currentFrameRate >= 120 ? 0.12 : 0.14
            bitrateBased = Int((bytesPerSecond * windowSeconds).rounded())
        } else {
            bitrateBased = 0
        }
        let computed = max(pixelBased, bitrateBased)
        let isProRes = encoderConfig.codec == .proRes4444
        let queueCap: Int
        if isProRes {
            queueCap = 40_000_000
        } else {
            queueCap = maxQueuedBytesCap
        }
        let clamped = max(minQueuedBytes, min(queueCap, computed))
        maxQueuedBytes = clamped
        let pressureRatio: Double
        if isProRes {
            pressureRatio = 0.80
        } else {
            pressureRatio = 0.60
        }
        queuePressureBytes = max(minQueuedBytes, Int(Double(clamped) * pressureRatio))
    }
}
#endif
