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
struct StreamResizeRollbackSnapshot: Sendable {
    let baseCaptureSize: CGSize
    let currentEncodedSize: CGSize
    let currentCaptureSize: CGSize
    let activePixelFormat: MiragePixelFormat
    let lastWindowFrame: CGRect
    let streamScale: CGFloat
    let requestedStreamScale: CGFloat
    let captureMode: StreamContext.CaptureMode
    let dimensionToken: UInt16
    let currentContentRect: CGRect
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
            currentContentRect: currentContentRect
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
        frameInbox.clear()
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
        MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: baseSize,
            requestedStreamScale: streamScale,
            encoderMaxWidth: encoderMaxWidth ?? Int(Self.maxEncodedWidth),
            encoderMaxHeight: encoderMaxHeight ?? Int(Self.maxEncodedHeight),
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
        let isGameMode = performanceMode == .game
        let frameRateFactor: Double = if isGameMode {
            currentFrameRate >= 120 ? 0.30 : 0.24
        } else {
            currentFrameRate >= 120 ? 0.22 : 0.15
        }
        let pixelBased = Int((pixelCount * frameRateFactor).rounded())
        let bitrateBased: Int
        if let bitrate = encoderConfig.bitrate, bitrate > 0 {
            let bytesPerSecond = Double(bitrate) / 8.0
            let windowSeconds: Double = if isGameMode {
                currentFrameRate >= 120 ? 0.20 : 0.24
            } else {
                currentFrameRate >= 120 ? 0.12 : 0.14
            }
            bitrateBased = Int((bytesPerSecond * windowSeconds).rounded())
        } else {
            bitrateBased = 0
        }
        let computed = max(pixelBased, bitrateBased)
        let isProRes = encoderConfig.codec == .proRes4444
        let queueCap: Int
        if isProRes {
            queueCap = 40_000_000
        } else if isGameMode {
            queueCap = Self.gameModeQueueCapBytes
        } else {
            queueCap = maxQueuedBytesCap
        }
        let clamped = max(minQueuedBytes, min(queueCap, computed))
        maxQueuedBytes = clamped
        let pressureRatio: Double
        if isProRes {
            pressureRatio = 0.80
        } else if isGameMode {
            pressureRatio = Self.gameModeQueuePressureRatio
        } else {
            pressureRatio = 0.60
        }
        queuePressureBytes = max(minQueuedBytes, Int(Double(clamped) * pressureRatio))
    }
}
#endif
