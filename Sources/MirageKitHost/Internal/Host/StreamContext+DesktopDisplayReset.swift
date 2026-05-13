//
//  StreamContext+DesktopDisplayReset.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Rebuilds desktop display capture after the backing display mode or topology changes.
    func hardResetDesktopDisplayCapture(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize
    )
    async throws {
        guard isRunning else { return }
        guard resolution.width > 0, resolution.height > 0 else { return }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero
        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        markDiscontinuity(reason: "desktop resize reset", advanceEpoch: true)
        await packetSender?.bumpGeneration(reason: "desktop resize reset")
        await packetSender?.resetQueue(reason: "desktop resize reset")
        resetPipelineStateForReconfiguration(reason: "desktop resize reset")

        baseCaptureSize = resolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        guard scaledWidth > 0, scaledHeight > 0 else { return }

        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()

        await captureEngine?.stopCapture()

        guard let encoder else { throw MirageError.protocolError("Desktop resize reset missing encoder") }
        try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
        try await encoder.reset()
        let resolvedPixelFormat = await encoder.activePixelFormat
        activePixelFormat = resolvedPixelFormat

        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let restartCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: CGVirtualDisplayBridge.isMirageDisplay(displayWrapper.display.displayID)
        )
        captureEngine = restartCaptureEngine
        if let captureStallStageHandler {
            await restartCaptureEngine.setCaptureStallStageHandler(captureStallStageHandler)
        }
        let frameInbox = frameInbox
        await restartCaptureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot
            let pendingPressure = snapshot.pending >= max(1, snapshot.capacity - 1)
            let backpressure = self?.backpressureActiveSnapshot ?? false
            guard pendingPressure || backpressure else { return false }

            if frameInbox.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }

        try await restartCaptureEngine.startDisplayCapture(
            display: displayWrapper.display,
            resolution: outputSize,
            showsCursor: captureShowsCursor,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
            audioChannelCount: requestedAudioChannelCount
        )
        await refreshCaptureCadence()
        await applyDerivedQuality(for: outputSize, logLabel: "Desktop resize reset")
        if encodingSuspendedForResize {
            MirageLogger.stream("Desktop resize reset deferred recovery keyframe until encoding resume")
        } else {
            await scheduleCoalescedRecoveryKeyframe(
                reason: "Desktop resize reset",
                ignoreExistingInFlight: true
            )
        }
        MirageLogger.stream("Desktop display reset complete at \(scaledWidth)x\(scaledHeight)")
    }
}
#endif
