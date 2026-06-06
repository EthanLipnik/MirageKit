//
//  StreamContext+Streaming+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream update and shutdown helpers.
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
import ScreenCaptureKit

extension StreamContext {
    func updateQualityAdjustmentPolicy(
        runtimeQualityAdjustmentEnabled: Bool?,
        encoderCatchUpQualityAdjustmentEnabled: Bool?
    ) {
        if let runtimeQualityAdjustmentEnabled {
            self.runtimeQualityAdjustmentEnabled = runtimeQualityAdjustmentEnabled
        }
        if let encoderCatchUpQualityAdjustmentEnabled {
            self.encoderCatchUpQualityAdjustmentEnabled = encoderCatchUpQualityAdjustmentEnabled
        }
    }

    func applyRealtimeBudgetBitrate(
        _ bitrate: Int,
        ceilingBitrateBps: Int?,
        encoderRateHintBps: Int? = nil,
        senderPacingBitrateBps: Int? = nil,
        minimumBitrateFloorBps: Int? = nil,
        reason: String
    ) async {
        guard isRunning else { return }
        guard let normalizedBitrate = MirageMedia.MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: bitrate
        ) else { return }
        let ceiling = ceilingBitrateBps ?? bitrateAdaptationCeiling ?? requestedTargetBitrate ?? normalizedBitrate
        let minimumBitrateFloor = max(1, minimumBitrateFloorBps ?? realtimeMinimumBitrateFloorBps)
        let targetBitrate = min(
            max(minimumBitrateFloor, normalizedBitrate),
            max(minimumBitrateFloor, ceiling)
        )
        guard targetBitrate > 0 else { return }
        let normalizedEncoderRateHint = MirageMedia.MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: encoderRateHintBps ?? targetBitrate
        ) ?? targetBitrate
        let encoderRateHint = min(
            max(minimumBitrateFloor, normalizedEncoderRateHint),
            max(minimumBitrateFloor, ceiling)
        )
        let normalizedSenderPacingBitrate = MirageMedia.MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: senderPacingBitrateBps ?? targetBitrate
        ) ?? targetBitrate
        let senderPacingMinimumFloor = mediaPathProfile.usesAwdlRadioPolicy ? 1 : minimumBitrateFloor
        let senderPacingBitrate = min(
            max(senderPacingMinimumFloor, normalizedSenderPacingBitrate),
            max(senderPacingMinimumFloor, ceiling)
        )
        let now = CFAbsoluteTimeGetCurrent()
        let transportBitrateChanged = targetBitrate != currentTargetBitrateBps
        let desiredEncoderHintChanged = encoderRateHint != realtimeEncoderRateHintBps
        let senderPacingChanged = senderPacingBitrate != realtimeSenderPacingBitrateBps
        guard transportBitrateChanged || desiredEncoderHintChanged || senderPacingChanged else {
            await refreshRuntimeQualityTargets(for: encoderRateHint, reason: reason)
            return
        }

        let previousBitrate = encoderConfig.bitrate
        let previousEncoderRate = previousBitrate ?? 0
        let isEncoderRaise = encoderRateHint > previousEncoderRate
        let raiseRatio = previousEncoderRate > 0
            ? Double(encoderRateHint) / Double(previousEncoderRate)
            : Double.infinity
        let shouldApplyEncoderRetune = !isEncoderRaise ||
            previousEncoderRate == 0 ||
            raiseRatio >= 1.12 ||
            now - realtimeLastEncoderRateRaiseTime >= 0.25
        let encoderHintChanged = shouldApplyEncoderRetune && encoderRateHint != encoderConfig.bitrate
        if shouldApplyEncoderRetune {
            encoderConfig.bitrate = encoderRateHint
        }
        currentTargetBitrateBps = targetBitrate
        realtimeEncoderRateHintBps = encoderRateHint
        realtimeSenderPacingBitrateBps = senderPacingBitrate
        await packetSender?.setTargetBitrateBps(senderPacingBitrate)
        if encoderHintChanged {
            await encoder?.updateBitrate(encoderRateHint)
            scheduleRateControlRetuneValidation(
                previousBitrate: previousBitrate,
                targetBitrate: encoderRateHint
            )
            if isEncoderRaise {
                realtimeLastEncoderRateRaiseTime = now
            }
        }
        await refreshRuntimeQualityTargets(for: encoderRateHint, reason: reason)

        MirageLogger.metrics(
            "Realtime stream budget applied encoded-frame budget for stream \(streamID): " +
                "target=\(targetBitrate) ceiling=\(ceiling) encoderHint=\(encoderRateHint) " +
                "senderPacing=\(senderPacingBitrate) retune=\(shouldApplyEncoderRetune) reason=\(reason)"
        )
        logBitrateContract(event: "realtime_budget_update")
    }

    func updateEncoderSettings(
        colorDepth: MirageMedia.MirageStreamColorDepth?,
        bitrate: Int?,
        bitrateAdaptationCeiling: Int? = nil,
        updateRequestedTargetBitrate: Bool = false
    ) async throws {
        guard isRunning else { return }

        let previousBitrateAdaptationCeiling = self.bitrateAdaptationCeiling
        if let bitrateAdaptationCeiling {
            self.bitrateAdaptationCeiling = max(1, bitrateAdaptationCeiling)
        }
        let effectiveBitrateAdaptationCeiling = self.bitrateAdaptationCeiling

        var updatedConfig = encoderConfig.withOverrides(
            colorDepth: colorDepth,
            bitrate: bitrate
        )
        if let normalizedBitrate = MirageMedia.MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: updatedConfig.bitrate
        ) {
            updatedConfig.bitrate = normalizedBitrate
        }
        if let effectiveBitrateAdaptationCeiling,
           let updatedBitrate = updatedConfig.bitrate,
           updatedBitrate > effectiveBitrateAdaptationCeiling {
            updatedConfig.bitrate = effectiveBitrateAdaptationCeiling
        }

        let colorDepthChanged = updatedConfig.colorDepth != encoderConfig.colorDepth
        let bitrateChanged = updatedConfig.bitrate != encoderConfig.bitrate
        let frameRateChanged = updatedConfig.targetFrameRate != encoderConfig.targetFrameRate
        let bitrateAdaptationCeilingChanged = previousBitrateAdaptationCeiling != self.bitrateAdaptationCeiling
        guard colorDepthChanged || bitrateChanged || frameRateChanged || bitrateAdaptationCeilingChanged else { return }

        let updatedRequestedTargetBitrate: Int? = if updateRequestedTargetBitrate,
                                                     bitrate != nil,
                                                     let updatedBitrate = updatedConfig.bitrate {
            min(updatedBitrate, effectiveBitrateAdaptationCeiling ?? updatedBitrate)
        } else if bitrateAdaptationCeilingChanged,
                  let requestedTargetBitrate,
                  let effectiveBitrateAdaptationCeiling {
            min(requestedTargetBitrate, effectiveBitrateAdaptationCeiling)
        } else {
            requestedTargetBitrate
        }

        if (bitrateChanged || bitrateAdaptationCeilingChanged), !colorDepthChanged, !frameRateChanged {
            let previousBitrate = encoderConfig.bitrate
            encoderConfig = updatedConfig
            currentTargetBitrateBps = encoderConfig.bitrate
            requestedTargetBitrate = updatedRequestedTargetBitrate
            if bitrateChanged {
                realtimeSenderPacingBitrateBps = encoderConfig.bitrate
                await packetSender?.setTargetBitrateBps(encoderConfig.bitrate)
                await encoder?.updateBitrate(encoderConfig.bitrate)
                scheduleRateControlRetuneValidation(
                    previousBitrate: previousBitrate,
                    targetBitrate: encoderConfig.bitrate
                )
            }
            if currentEncodedSize != .zero {
                await applyDerivedQuality(for: currentEncodedSize, logLabel: "Bitrate update")
            }
            let bitrateText = encoderConfig.bitrate.map(String.init) ?? "auto"
            let ceilingText = self.bitrateAdaptationCeiling.map(String.init) ?? "nil"
            MirageLogger.stream("Encoder bitrate update applied: bitrate=\(bitrateText), ceiling=\(ceilingText)")
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
        currentTargetBitrateBps = encoderConfig.bitrate
        requestedTargetBitrate = updatedRequestedTargetBitrate
        ultraValidationFailureHandled = false
        ultraValidationSuccessLogged = false

        realtimeSenderPacingBitrateBps = encoderConfig.bitrate
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
            scheduleProcessingIfNeeded()
        }

        let bitrateText = encoderConfig.bitrate.map(String.init) ?? "auto"
        MirageLogger
            .stream(
                "Encoder settings update applied: colorDepth=\(encoderConfig.colorDepth.displayName), bitrate=\(bitrateText)"
            )
        logBitrateContract(event: "encoder_settings_update")
    }

    func updateFrameRate(_ fps: Int, updatesAwdlInteractiveCeiling: Bool = true) async throws {
        let clamped = MirageAwdlMediaController.fixedDisplayTargetFrameRate(
            requestedFrameRate: fps,
            mediaPathProfile: mediaPathProfile
        )
        let previousFrameRate = currentFrameRate
        captureFrameRateOverride = clamped
        let desiredCaptureRate = resolvedCaptureFrameRate(for: clamped)
        currentFrameRate = clamped
        if updatesAwdlInteractiveCeiling {
            awdlInteractiveFrameRateCeiling = clamped
        }
        encoderConfig = encoderConfig.withTargetFrameRate(clamped)
        adaptivePFrameController.retuneForFrameRateChange(
            from: previousFrameRate,
            to: clamped,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            maxPayloadSize: maxPayloadSize,
            mediaPathProfile: mediaPathProfile
        )
        if isRunning, let captureEngine {
            if desiredCaptureRate != captureFrameRate {
                try await captureEngine.updateFrameRate(desiredCaptureRate)
            }
            await refreshCaptureCadence()
        } else {
            captureFrameRate = desiredCaptureRate
        }
        await encoder?.updateFrameRate(clamped)
        if currentEncodedSize != .zero {
            await applyDerivedQuality(for: currentEncodedSize, logLabel: "Frame rate update")
        }
        updateKeyframeCadence()
        updateQueueLimits()
        MirageLogger.stream("Stream \(streamID) frame rate updated to \(clamped) fps (capture \(captureFrameRate) fps)")
    }

    func updateCaptureShowsCursor(_ showsCursor: Bool) async throws {
        guard captureShowsCursor != showsCursor else { return }
        captureShowsCursor = showsCursor
        try await updateActiveCaptureShowsCursor(showsCursor)
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
            try await updateActiveWindowCaptureDimensions(windowFrame: windowFrame, outputScale: streamScale)

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
        let candidateScaledWidth = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.width * candidateScale)
        let candidateScaledHeight = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.height * candidateScale)
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
        let scaledWidth = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.width * resolvedScaleForUpdate)
        let scaledHeight = MirageMedia.MirageStreamGeometry.alignedEncodedDimension(requestedBaseSize.height * resolvedScaleForUpdate)
        let outputSize = CGSize(width: CGFloat(scaledWidth), height: CGFloat(scaledHeight))

        baseCaptureSize = requestedBaseSize
        streamScale = resolvedScaleForUpdate
        captureMode = .display

        MirageLogger
            .stream(
                "Updating to client-requested resolution: \(width)x\(height) (scaled \(scaledWidth)x\(scaledHeight)) (frames paused)"
            )
        do {
            try await updateActiveCaptureResolution(width: scaledWidth, height: scaledHeight)

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
        let scaleReason = if clampedScale < previousScale {
            "adaptive-downscale-client-requested"
        } else if clampedScale > previousScale {
            "adaptive-restore-client-requested"
        } else {
            adaptiveStreamScaleReason
        }

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
        adaptiveStreamScaleReason = scaleReason

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
            switch captureMode {
            case .display:
                try await updateActiveCaptureResolution(width: scaledWidth, height: scaledHeight)
            case .window:
                if !lastWindowFrame.isEmpty {
                    try await updateActiveWindowCaptureDimensions(windowFrame: lastWindowFrame, outputScale: streamScale)
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

    func updateEmergencyRecoveryScale(
        _ newScale: CGFloat,
        reason: String,
        advancesDimensionToken: Bool = false
    ) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
        let rollbackSnapshot = makeResizeRollbackSnapshot()
        let previousScale = streamScale
        let derivedBaseSize: CGSize
        if baseCaptureSize != .zero {
            derivedBaseSize = baseCaptureSize
        } else if previousScale > 0 {
            let fallbackSize = currentCaptureSize == .zero ? currentEncodedSize : currentCaptureSize
            derivedBaseSize = CGSize(
                width: fallbackSize.width / previousScale,
                height: fallbackSize.height / previousScale
            )
        } else {
            derivedBaseSize = currentCaptureSize
        }
        guard derivedBaseSize.width > 0, derivedBaseSize.height > 0 else { return }

        let resolvedScale = resolvedStreamScale(
            for: derivedBaseSize,
            requestedScale: clampedScale,
            logLabel: nil
        )
        guard abs(Double(resolvedScale - streamScale)) > 0.0001 else { return }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        if advancesDimensionToken {
            dimensionToken &+= 1
            MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        }
        await packetSender?.bumpGeneration(reason: "emergency recovery scale update")
        resetPipelineStateForReconfiguration(
            reason: "emergency recovery scale update",
            preservePendingGeometryRecoveryKeyframe: true
        )

        baseCaptureSize = derivedBaseSize
        streamScale = resolvedScale
        adaptiveStreamScaleReason = "emergency-recovery-\(reason)"

        let outputSize = scaledOutputSize(for: derivedBaseSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        MirageLogger.stream(
            "Emergency recovery scale update sizing: base \(Int(derivedBaseSize.width))x\(Int(derivedBaseSize.height)), " +
                "requested \(requestedStreamScale), recoveryScale \(streamScale), " +
                "encoded \(scaledWidth)x\(scaledHeight), token \(dimensionToken)"
        )

        do {
            switch captureMode {
            case .display:
                try await updateActiveCaptureResolution(width: scaledWidth, height: scaledHeight)
            case .window:
                if !lastWindowFrame.isEmpty {
                    try await updateActiveWindowCaptureDimensions(windowFrame: lastWindowFrame, outputScale: streamScale)
                }
            }

            if let encoder {
                try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
                updateQueueLimits()
            }
            updateQueueLimits()

            await applyDerivedQuality(for: outputSize, logLabel: "Emergency recovery scale update")
            MirageLogger.stream(
                "Emergency recovery scale updated to \(streamScale), encoding at " +
                    "\(Int(outputSize.width))x\(Int(outputSize.height)), token \(dimensionToken)"
            )
        } catch {
            do {
                try await rollbackResizeFailure(rollbackSnapshot, logLabel: "Emergency recovery scale update")
            } catch {
                MirageLogger.error(.stream, error: error, message: "Emergency recovery scale rollback failed: ")
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
