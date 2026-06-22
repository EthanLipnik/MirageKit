//
//  StreamContext+DesktopDisplayReset.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

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

        if let captureSourceBackend {
            await captureSourceBackend.stopCapture()
            self.captureSourceBackend = nil
        } else {
            await captureEngine?.stopCapture()
        }

        guard let encoder else { throw MirageCore.MirageError.protocolError("Desktop resize reset missing encoder") }
        try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
        try await encoder.reset()
        let resolvedPixelFormat = await encoder.activePixelFormat
        activePixelFormat = resolvedPixelFormat

        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let restartCaptureEngine = captureEngineFactoryBackend.makeCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: virtualDisplayBackend.isMirageDisplay(displayWrapper.display.displayID)
        )
        captureEngine = restartCaptureEngine
        if let captureStallStageHandler {
            await restartCaptureEngine.setCaptureStallStageHandler(captureStallStageHandler)
        }
        let frameInbox = frameInbox
        let latencyMode = latencyMode
        let hostBufferingPolicy = hostBufferingPolicy
        await restartCaptureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot
            let backpressure = self?.backpressureActiveSnapshot ?? false
            let encoderLag = HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: self?.encoderAverageEncodeMsSnapshot ?? 0,
                inFlightCount: self?.encoderInFlightCountSnapshot ?? 0,
                frameRate: self?.currentFrameRate ?? 60
            )
            let shouldDrop = HostCaptureAdmissionPolicy.shouldDropCapturedFrame(
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                pendingFrameCount: snapshot.pending,
                frameCapacity: snapshot.capacity,
                backpressureActive: backpressure,
                encoderLag: encoderLag
            )
            guard shouldDrop else { return false }

            if frameInbox.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }

        let captureSourceBackend = makeCaptureSourceBackend()
        try await captureSourceBackend.startCapture(
            MirageHostCaptureRequest(
                source: .display(MirageHostDisplayID(displayWrapper.display.displayID)),
                configuration: MirageHostCaptureConfiguration(
                    logicalSize: outputSize,
                    captureResolution: outputSize,
                    showsCursor: captureShowsCursor,
                    targetFrameRate: currentFrameRate,
                    queueDepth: encoderConfig.captureQueueDepth ?? 1,
                    capturesAudio: onCapturedAudioBuffer != nil,
                    audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: onCapturedAudioBuffer != nil),
                    audioChannelCount: requestedAudioChannelCount
                )
            ),
            using: restartCaptureEngine,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer,
        )
        await refreshCaptureCadence()
        await applyDerivedQuality(for: outputSize, logLabel: "Desktop resize reset")
        if encodingSuspendedForResize {
            MirageLogger.stream("Desktop resize reset deferred recovery keyframe until encoding resume")
        } else {
            await scheduleCoalescedRecoveryKeyframe(
                reason: "Desktop resize reset",
                noteLoss: true,
                ignoreExistingInFlight: true,
                supersedesInFlightGeometry: true,
                bypassesRecoveryCooldown: true
            )
        }
        MirageLogger.stream("Desktop display reset complete at \(scaledWidth)x\(scaledHeight)")
    }
}
#endif
