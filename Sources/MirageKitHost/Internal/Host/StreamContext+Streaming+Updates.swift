//
//  StreamContext+Streaming+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream update and shutdown helpers.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func updateEncoderSettings(
        colorDepth: MirageStreamColorDepth?,
        bitrate: Int?,
        updateRequestedTargetBitrate: Bool = false
    ) async throws {
        guard isRunning else { return }

        var updatedConfig = encoderConfig.withOverrides(
            colorDepth: colorDepth,
            bitrate: bitrate
        )
        if let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: updatedConfig.bitrate
        ) {
            updatedConfig.bitrate = normalizedBitrate
        }
        if let bitrateAdaptationCeiling,
           let updatedBitrate = updatedConfig.bitrate,
           updatedBitrate > bitrateAdaptationCeiling {
            updatedConfig.bitrate = bitrateAdaptationCeiling
        }

        let colorDepthChanged = updatedConfig.colorDepth != encoderConfig.colorDepth
        let bitrateChanged = updatedConfig.bitrate != encoderConfig.bitrate
        let frameRateChanged = updatedConfig.targetFrameRate != encoderConfig.targetFrameRate
        guard colorDepthChanged || bitrateChanged || frameRateChanged else { return }

        let updatedRequestedTargetBitrate: Int? = if updateRequestedTargetBitrate,
                                                     bitrate != nil,
                                                     let updatedBitrate = updatedConfig.bitrate {
            min(updatedBitrate, bitrateAdaptationCeiling ?? updatedBitrate)
        } else {
            requestedTargetBitrate
        }

        if bitrateChanged, !colorDepthChanged, !frameRateChanged {
            encoderConfig = updatedConfig
            requestedTargetBitrate = updatedRequestedTargetBitrate
            await packetSender?.setTargetBitrateBps(encoderConfig.bitrate)
            await encoder?.updateBitrate(encoderConfig.bitrate)
            if currentEncodedSize != .zero {
                await applyDerivedQuality(for: currentEncodedSize, logLabel: "Bitrate update")
            }
            let bitrateText = encoderConfig.bitrate.map(String.init) ?? "auto"
            MirageLogger.stream("Encoder bitrate update applied: bitrate=\(bitrateText)")
            logBitrateContract(event: "bitrate_update")
            return
        }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "encoder settings update")
        resetPipelineStateForReconfiguration(reason: "encoder settings update")

        encoderConfig = updatedConfig
        requestedTargetBitrate = updatedRequestedTargetBitrate
        ultraValidationFailureHandled = false
        ultraValidationSuccessLogged = false

        await packetSender?.setTargetBitrateBps(encoderConfig.bitrate)
        if let encoder {
            try await encoder.updateConfiguration(encoderConfig)
            let resolvedPixelFormat = await encoder.activePixelFormat
            activePixelFormat = resolvedPixelFormat
            encoderConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        }
        if let captureEngine { try await captureEngine.updateConfiguration(encoderConfig) }
        updateQueueLimits()
        if currentEncodedSize != .zero {
            await applyDerivedQuality(for: currentEncodedSize, logLabel: "Encoder settings update")
        }

        if queueKeyframe(
            reason: "Encoder settings update",
            checkInFlight: false,
            requiresFlush: true,
            requiresReset: true,
            urgent: true
        ) {
            noteLossEvent(reason: "Encoder settings update", enablePFrameFEC: true)
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }

        let bitrateText = encoderConfig.bitrate.map(String.init) ?? "auto"
        MirageLogger
            .stream(
                "Encoder settings update applied: colorDepth=\(encoderConfig.colorDepth.displayName), bitrate=\(bitrateText)"
            )
        logBitrateContract(event: "encoder_settings_update")
    }

    func updateFrameRate(_ fps: Int) async throws {
        guard isRunning else { return }
        let clamped = max(1, fps)
        currentFrameRate = clamped
        lastFrameRateThrottleAdmissionTime = 0
        encoderConfig = encoderConfig.withTargetFrameRate(clamped)
        await encoder?.updateFrameRate(clamped)
        if currentEncodedSize != .zero {
            await applyDerivedQuality(for: currentEncodedSize, logLabel: "Frame rate update")
        }
        updateKeyframeCadence()
        updateQueueLimits()
        MirageLogger.stream(
            "Stream \(streamID) target frame rate updated to \(clamped) fps " +
                "(capture remains \(captureFrameRate) fps, frames are skipped before encode)"
        )
    }

    func updateCaptureShowsCursor(_ showsCursor: Bool) async throws {
        guard captureShowsCursor != showsCursor else { return }
        captureShowsCursor = showsCursor
        try await captureEngine?.updateShowsCursor(showsCursor)
        MirageLogger.stream("Stream \(streamID) capture cursor visibility updated: showsCursor=\(showsCursor)")
    }

    func updateDimensions(windowFrame: CGRect) async throws {
        guard isRunning else { return }
        let rollbackSnapshot = makeResizeRollbackSnapshot()

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "dimension update")
        resetPipelineStateForReconfiguration(reason: "dimension update")

        let captureTarget = streamTargetDimensions(windowFrame: windowFrame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        lastWindowFrame = windowFrame
        captureMode = .window

        MirageLogger
            .stream(
                "Updating stream to scaled resolution: \(width)x\(height) (capture \(captureTarget.width)x\(captureTarget.height), scale: \(captureTarget.hostScaleFactor), from \(windowFrame.width)x\(windowFrame.height) pts) (frames paused)"
            )
        do {
            if let captureEngine {
                try await captureEngine.updateDimensions(windowFrame: windowFrame, outputScale: streamScale)
            }

            if let encoder {
                try await encoder.updateDimensions(width: width, height: height)
            }
            await applyDerivedQuality(for: outputSize, logLabel: "Dimension update")

            await encoder?.forceKeyframe()

            MirageLogger.stream("Dimension update complete (frames resumed)")
        } catch {
            do {
                try await rollbackResizeFailure(rollbackSnapshot, logLabel: "Dimension update")
            } catch {
                MirageLogger.error(.stream, error: error, message: "Dimension update rollback failed: ")
            }
            throw error
        }
    }

    func updateResolution(width: Int, height: Int) async throws {
        guard isRunning else { return }
        let rollbackSnapshot = makeResizeRollbackSnapshot()

        let requestedBaseSize = CGSize(width: width, height: height)
        guard requestedBaseSize.width > 0, requestedBaseSize.height > 0 else { return }

        let candidateScale = resolvedStreamScale(
            for: requestedBaseSize,
            requestedScale: requestedStreamScale,
            logLabel: nil
        )
        let candidateScaledWidth = MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.width * candidateScale)
        let candidateScaledHeight = MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.height * candidateScale)
        let candidateOutputSize = CGSize(width: CGFloat(candidateScaledWidth), height: CGFloat(candidateScaledHeight))

        if requestedBaseSize == baseCaptureSize,
           candidateScale == streamScale,
           candidateOutputSize == currentEncodedSize {
            MirageLogger.stream("Resolution update skipped (no change)")
            return
        }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "resolution update")
        resetPipelineStateForReconfiguration(reason: "resolution update")

        let resolvedScaleForUpdate = resolvedStreamScale(
            for: requestedBaseSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let scaledWidth = MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.width * resolvedScaleForUpdate)
        let scaledHeight = MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.height * resolvedScaleForUpdate)
        let outputSize = CGSize(width: CGFloat(scaledWidth), height: CGFloat(scaledHeight))

        baseCaptureSize = requestedBaseSize
        streamScale = resolvedScaleForUpdate
        captureMode = .display

        MirageLogger
            .stream(
                "Updating to client-requested resolution: \(width)x\(height) (scaled \(scaledWidth)x\(scaledHeight)) (frames paused)"
            )
        do {
            if let captureEngine {
                try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
            }

            currentCaptureSize = outputSize
            currentEncodedSize = outputSize
            updateQueueLimits()

            if let encoder {
                try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
                updateQueueLimits()
            }

            await encoder?.forceKeyframe()

            MirageLogger.stream("Resolution update to \(scaledWidth)x\(scaledHeight) complete (frames resumed)")
        } catch {
            do {
                try await rollbackResizeFailure(rollbackSnapshot, logLabel: "Resolution update")
            } catch {
                MirageLogger.error(.stream, error: error, message: "Resolution update rollback failed: ")
            }
            throw error
        }
    }

    func updateStreamScale(_ newScale: CGFloat) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
        let rollbackSnapshot = makeResizeRollbackSnapshot()
        let previousScale = streamScale

        let derivedBaseSize: CGSize
        if baseCaptureSize != .zero { derivedBaseSize = baseCaptureSize } else if previousScale > 0 {
            let fallbackSize = currentCaptureSize == .zero ? currentEncodedSize : currentCaptureSize
            derivedBaseSize = CGSize(
                width: fallbackSize.width / previousScale,
                height: fallbackSize.height / previousScale
            )
        } else {
            derivedBaseSize = currentCaptureSize
        }
        guard derivedBaseSize.width > 0, derivedBaseSize.height > 0 else {
            requestedStreamScale = clampedScale
            return
        }

        let resolvedScale = resolvedStreamScale(
            for: derivedBaseSize,
            requestedScale: clampedScale,
            logLabel: nil
        )
        if resolvedScale == streamScale {
            requestedStreamScale = clampedScale
            return
        }

        requestedStreamScale = clampedScale

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "stream scale update")
        resetPipelineStateForReconfiguration(reason: "stream scale update")

        baseCaptureSize = derivedBaseSize

        let resolvedScaleWithLog = resolvedStreamScale(
            for: derivedBaseSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        guard resolvedScaleWithLog != streamScale else { return }
        streamScale = resolvedScaleWithLog

        let outputSize = scaledOutputSize(for: derivedBaseSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        MirageLogger
            .stream(
                "Stream scale update sizing: base \(Int(derivedBaseSize.width))x\(Int(derivedBaseSize.height))," +
                    " requested \(requestedStreamScale)," +
                    " resolved \(streamScale)," +
                    " encoded \(scaledWidth)x\(scaledHeight)"
            )
        do {
            if let captureEngine {
                switch captureMode {
                case .display:
                    try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
                case .window:
                    if !lastWindowFrame.isEmpty {
                        try await captureEngine.updateDimensions(windowFrame: lastWindowFrame, outputScale: streamScale)
                    }
                }
            }

            if let encoder {
                try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
                updateQueueLimits()
            }
            updateQueueLimits()

            await applyDerivedQuality(for: outputSize, logLabel: "Stream scale update")
            await encoder?.forceKeyframe()
            MirageLogger
                .stream(
                    "Stream scale updated to \(streamScale), encoding at \(Int(outputSize.width))x\(Int(outputSize.height))"
                )
        } catch {
            do {
                try await rollbackResizeFailure(rollbackSnapshot, logLabel: "Stream scale update")
            } catch {
                MirageLogger.error(.stream, error: error, message: "Stream scale update rollback failed: ")
            }
            throw error
        }
    }

    func updateCaptureDisplay(_ displayWrapper: SCDisplayWrapper, resolution: CGSize) async throws {
        guard isRunning else { return }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "display switch")
        resetPipelineStateForReconfiguration(reason: "display switch")

        baseCaptureSize = resolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)

        MirageLogger
            .stream(
                "Switching to new display \(displayWrapper.display.displayID) at \(Int(resolution.width))x\(Int(resolution.height)) (scaled \(scaledWidth)x\(scaledHeight)) (frames paused)"
            )

        if let captureEngine { try await captureEngine.updateCaptureDisplay(displayWrapper.display, resolution: outputSize) }

        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()

        if let encoder { try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight) }

        await applyDerivedQuality(for: outputSize, logLabel: "Display switch")
        await encoder?.forceKeyframe()

        MirageLogger.stream("Display switch complete (frames resumed)")
    }

    func updateDisplayCaptureExclusions(_ windows: [SCWindowWrapper]) async {
        guard isRunning, captureMode == .display, let captureEngine else { return }
        let resolvedWindows = windows.map(\.window)
        do {
            try await captureEngine.updateExcludedWindows(resolvedWindows)
        } catch {
            MirageLogger.error(.stream, error: error, message: "Failed to update display capture exclusions: ")
        }
    }
}

#endif
