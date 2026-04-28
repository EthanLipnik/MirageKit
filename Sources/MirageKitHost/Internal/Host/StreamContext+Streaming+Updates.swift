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
    enum EncoderSettingsUpdateMode: Equatable {
        case noChange
        case bitrateOnly
        case fullReconfiguration
    }

    static func encoderSettingsUpdateMode(
        current: MirageEncoderConfiguration,
        updated: MirageEncoderConfiguration
    )
    -> EncoderSettingsUpdateMode {
        let colorDepthChanged = updated.colorDepth != current.colorDepth
        let bitrateChanged = updated.bitrate != current.bitrate
        let frameRateChanged = updated.targetFrameRate != current.targetFrameRate

        guard colorDepthChanged || bitrateChanged || frameRateChanged else {
            return .noChange
        }
        if bitrateChanged, !colorDepthChanged, !frameRateChanged {
            return .bitrateOnly
        }
        return .fullReconfiguration
    }

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

        let updateMode = Self.encoderSettingsUpdateMode(
            current: encoderConfig,
            updated: updatedConfig
        )
        guard updateMode != .noChange else { return }
        let updatedRequestedTargetBitrate: Int? = if updateRequestedTargetBitrate,
            bitrate != nil,
            let updatedBitrate = updatedConfig.bitrate {
            min(updatedBitrate, bitrateAdaptationCeiling ?? updatedBitrate)
        } else {
            requestedTargetBitrate
        }

        if updateMode == .bitrateOnly {
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
        if let captureEngine { try await captureEngine.updateConfiguration(encoderConfig) }
        if let encoder {
            try await encoder.updateConfiguration(encoderConfig)
            let resolvedPixelFormat = await encoder.getActivePixelFormat()
            activePixelFormat = resolvedPixelFormat
            encoderConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        }
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
        guard isRunning, let captureEngine else { return }
        let clamped = max(1, fps)
        captureFrameRateOverride = clamped
        let desiredCaptureRate = resolvedCaptureFrameRate(for: clamped)
        if desiredCaptureRate != captureFrameRate { try await captureEngine.updateFrameRate(desiredCaptureRate) }
        currentFrameRate = clamped
        encoderConfig = encoderConfig.withTargetFrameRate(clamped)
        await refreshCaptureCadence()
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
        try await captureEngine?.updateShowsCursor(showsCursor)
        MirageLogger.stream("Stream \(streamID) capture cursor visibility updated: showsCursor=\(showsCursor)")
    }

    @discardableResult
    func applyGameModeStage1FrameRateOverride() async -> Bool {
        guard currentFrameRate >= 120 || encoderConfig.targetFrameRate >= 120 else { return false }
        if isRunning, captureEngine != nil {
            do {
                try await updateFrameRate(60)
                return true
            } catch {
                MirageLogger.error(.stream, error: error, message: "Game mode stage 1 frame-rate override failed: ")
            }
        }

        let clamped = 60
        captureFrameRateOverride = clamped
        currentFrameRate = clamped
        captureFrameRate = clamped
        encoderConfig = encoderConfig.withTargetFrameRate(clamped)
        await encoder?.updateFrameRate(clamped)
        updateKeyframeCadence()
        updateQueueLimits()
        MirageLogger.stream("Game mode stage 1 applied without active capture: targetFrameRate=\(clamped)")
        return true
    }

    @discardableResult
    func applyGameModeStage2BitDepthOverride() async -> Bool {
        if let fallbackColorDepth = encoderConfig.colorDepth.nextLowerFallback {
            if isRunning {
                do {
                    try await updateEncoderSettings(
                        colorDepth: fallbackColorDepth,
                        bitrate: encoderConfig.bitrate
                    )
                    return true
                } catch {
                    MirageLogger.error(.stream, error: error, message: "Game mode stage 2 bit-depth override failed: ")
                    return false
                }
            }

            encoderConfig = encoderConfig.withOverrides(
                colorDepth: fallbackColorDepth,
                bitrate: encoderConfig.bitrate
            )
            activePixelFormat = encoderConfig.pixelFormat
            if currentEncodedSize != .zero {
                await applyDerivedQuality(for: currentEncodedSize, logLabel: "Game mode stage 2")
            }
            MirageLogger.stream(
                "Game mode stage 2 applied without active capture: colorDepth=\(fallbackColorDepth.displayName)"
            )
            return true
        }

        // If already at 8-bit, stage 2 still needs a meaningful fallback.
        let targetScale = max(
            Self.gameModeMinimumScale,
            StreamContext.clampStreamScale(streamScale * Self.gameModeStage2ScaleFactor)
        )
        guard targetScale + 0.001 < streamScale else { return false }

        if isRunning {
            do {
                try await updateStreamScale(targetScale)
                let scaleText = Double(streamScale).formatted(.number.precision(.fractionLength(2)))
                MirageLogger.stream(
                    "Game mode stage 2 applied via stream-scale fallback: \(scaleText)"
                )
                return true
            } catch {
                MirageLogger.error(.stream, error: error, message: "Game mode stage 2 scale override failed: ")
                return false
            }
        }

        requestedStreamScale = targetScale
        streamScale = targetScale
        if baseCaptureSize != .zero {
            let outputSize = scaledOutputSize(for: baseCaptureSize)
            currentCaptureSize = outputSize
            currentEncodedSize = outputSize
            updateQueueLimits()
            await applyDerivedQuality(for: outputSize, logLabel: "Game mode stage 2 scale")
        }
        let scaleText = Double(targetScale).formatted(.number.precision(.fractionLength(2)))
        MirageLogger.stream(
            "Game mode stage 2 applied without active capture: streamScale=\(scaleText)"
        )
        return true
    }

    @discardableResult
    func applyGameModeStage3EmergencyOverride() async -> Bool {
        gameModeAggressiveQualityDropEnabled = true
        qualityOverBudgetCount = 0
        qualityUnderBudgetCount = 0
        gameModeConsecutiveHealthyWindows = 0
        await encoder?.setGameModeEmergencyQualityClampsEnabled(true)

        let cap = Self.gameModeEmergencyBitrateCapBps
        let cappedBitrate = min(encoderConfig.bitrate ?? cap, cap)
        let normalizedCappedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: cappedBitrate
        ) ?? cappedBitrate
        let needsBitrateUpdate = encoderConfig.bitrate != normalizedCappedBitrate

        if needsBitrateUpdate {
            if isRunning {
                do {
                    try await updateEncoderSettings(
                        colorDepth: nil,
                        bitrate: normalizedCappedBitrate
                    )
                } catch {
                    MirageLogger.error(.stream, error: error, message: "Game mode stage 3 bitrate override failed: ")
                    return false
                }
            } else {
                encoderConfig = encoderConfig.withOverrides(bitrate: normalizedCappedBitrate)
                if currentEncodedSize != .zero {
                    await applyDerivedQuality(for: currentEncodedSize, logLabel: "Game mode stage 3")
                }
            }
        }

        return true
    }

    @discardableResult
    func restoreGameModeStage1FrameRateOverride() async -> Bool {
        let baselineFrameRate = max(1, gameModeBaselineFrameRate)
        guard encoderConfig.targetFrameRate != baselineFrameRate else { return false }
        if isRunning, captureEngine != nil {
            do {
                try await updateFrameRate(baselineFrameRate)
                return true
            } catch {
                MirageLogger.error(.stream, error: error, message: "Game mode stage 1 restore failed: ")
                return false
            }
        }

        captureFrameRateOverride = baselineFrameRate
        currentFrameRate = baselineFrameRate
        captureFrameRate = baselineFrameRate
        encoderConfig = encoderConfig.withTargetFrameRate(baselineFrameRate)
        await encoder?.updateFrameRate(baselineFrameRate)
        updateKeyframeCadence()
        updateQueueLimits()
        MirageLogger.stream("Game mode stage 1 restored without active capture: targetFrameRate=\(baselineFrameRate)")
        return true
    }

    @discardableResult
    func restoreGameModeStage2BitDepthOverride() async -> Bool {
        let baselineScale = StreamContext.clampStreamScale(gameModeBaselineStreamScale)
        let needsColorDepthRestore = encoderConfig.colorDepth != gameModeBaselineColorDepth
        let needsScaleRestore = abs(streamScale - baselineScale) > 0.001
        guard needsColorDepthRestore || needsScaleRestore else { return false }

        if isRunning {
            do {
                if needsColorDepthRestore {
                    try await updateEncoderSettings(
                        colorDepth: gameModeBaselineColorDepth,
                        bitrate: encoderConfig.bitrate
                    )
                }
                if needsScaleRestore {
                    try await updateStreamScale(baselineScale)
                }
                return true
            } catch {
                MirageLogger.error(.stream, error: error, message: "Game mode stage 2 restore failed: ")
                return false
            }
        }

        if needsColorDepthRestore {
            encoderConfig = encoderConfig.withOverrides(
                colorDepth: gameModeBaselineColorDepth,
                bitrate: encoderConfig.bitrate
            )
            activePixelFormat = encoderConfig.pixelFormat
        }
        if needsScaleRestore {
            requestedStreamScale = baselineScale
            streamScale = baselineScale
            if baseCaptureSize != .zero {
                let outputSize = scaledOutputSize(for: baseCaptureSize)
                currentCaptureSize = outputSize
                currentEncodedSize = outputSize
            }
            updateQueueLimits()
        }
        if currentEncodedSize != .zero {
            await applyDerivedQuality(for: currentEncodedSize, logLabel: "Game mode stage 2 restore")
        }
        let baselineScaleText = Double(baselineScale).formatted(.number.precision(.fractionLength(2)))
        MirageLogger.stream(
            "Game mode stage 2 restored without active capture: colorDepth=\(gameModeBaselineColorDepth.displayName), " +
                "streamScale=\(baselineScaleText)"
        )
        return true
    }

    @discardableResult
    func restoreGameModeStage3EmergencyOverride() async -> Bool {
        let hadEmergencyQualityDrops = gameModeAggressiveQualityDropEnabled
        gameModeAggressiveQualityDropEnabled = false
        qualityOverBudgetCount = 0
        qualityUnderBudgetCount = 0
        await encoder?.setGameModeEmergencyQualityClampsEnabled(false)

        let needsBitrateUpdate = encoderConfig.bitrate != gameModeBaselineBitrate
        if needsBitrateUpdate {
            if isRunning {
                do {
                    try await updateEncoderSettings(
                        colorDepth: nil,
                        bitrate: gameModeBaselineBitrate
                    )
                    return true
                } catch {
                    MirageLogger.error(.stream, error: error, message: "Game mode stage 3 restore failed: ")
                    return hadEmergencyQualityDrops
                }
            } else {
                encoderConfig = encoderConfig.withOverrides(bitrate: gameModeBaselineBitrate)
                if currentEncodedSize != .zero {
                    await applyDerivedQuality(for: currentEncodedSize, logLabel: "Game mode stage 3 restore")
                }
            }
        }

        return hadEmergencyQualityDrops || needsBitrateUpdate
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
        let candidateScaledWidth = StreamContext.alignedEvenPixel(requestedBaseSize.width * candidateScale)
        let candidateScaledHeight = StreamContext.alignedEvenPixel(requestedBaseSize.height * candidateScale)
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
        let scaledWidth = StreamContext.alignedEvenPixel(requestedBaseSize.width * resolvedScaleForUpdate)
        let scaledHeight = StreamContext.alignedEvenPixel(requestedBaseSize.height * resolvedScaleForUpdate)
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
        advanceEpoch(reason: "desktop resize reset")
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
        let resolvedPixelFormat = await encoder.getActivePixelFormat()
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
        let frameInbox = self.frameInbox
        await restartCaptureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot()
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
        let keyframeStrategy = desktopResizeRecoveryKeyframeStrategy(
            encodingSuspendedForResize: encodingSuspendedForResize
        )
        if keyframeStrategy == .scheduleDuringReset {
            await scheduleCoalescedRecoveryKeyframe(
                reason: "Desktop resize reset",
                ignoreExistingInFlight: true
            )
        } else {
            MirageLogger.stream("Desktop resize reset deferred recovery keyframe until encoding resume")
        }
        MirageLogger.stream("Desktop display reset complete at \(scaledWidth)x\(scaledHeight)")
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

    func pauseForClientBackground() async {
        guard shouldEncodeFrames else { return }
        shouldEncodeFrames = false
        frameInbox.clear()
        await packetSender?.resetQueue(reason: "client background pause")
        MirageLogger.stream("Stream \(streamID) paused for client background")
    }

    func resumeAfterClientForeground() async {
        guard !shouldEncodeFrames else { return }
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if let encoder {
            await encoder.resetFrameNumber()
            await encoder.forceKeyframe()
        }
        shouldEncodeFrames = true
        MirageLogger.stream("Stream \(streamID) resumed after client foreground")
    }

    func suspendEncodingForDesktopResize() async {
        guard !encodingSuspendedForResize else { return }
        encodingSuspendedForResize = true
        shouldEncodeFrames = false
        frameInbox.clear()
        resetPipelineStateForReconfiguration(reason: "desktop resize preflight pause")
        await packetSender?.resetQueue(reason: "desktop resize preflight pause")
        MirageLogger.stream("Desktop resize preflight: encoding suspended")
    }

    func resumeEncodingAfterDesktopResize() async {
        guard encodingSuspendedForResize else { return }
        encodingSuspendedForResize = false
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        shouldEncodeFrames = true
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize resume",
            resetFrameNumber: true,
            ignoreExistingInFlight: true
        )
        MirageLogger.stream("Desktop resize completion: encoding resumed")
    }

    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if !startupRegistrationLogged {
            startupRegistrationLogged = true
            logStartupEvent("UDP registration confirmed")
        }
        enableStartupTransportProtection(now: now)
        noteLossEvent(reason: "UDP registration warmup", enablePFrameFEC: true)

        // Configure the encoder for a keyframe BEFORE allowing frames through.
        // The await calls below suspend this actor, which would let queued
        // processPendingFrames() tasks interleave and encode a P-frame before
        // the encoder has frameNumber == 0 / forceNextKeyframe set.
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Startup registration confirmed",
            resetFrameNumber: true,
            noteLoss: true
        )

        let releaseDisposition = startupFrameReleaseDisposition(
            hasCachedFrame: cachedStartupFrame != nil,
            hasQueuedFrame: frameInbox.hasPending()
        )
        let cachedStartupFrame = self.cachedStartupFrame
        self.cachedStartupFrame = nil
        startupFrameCachingEnabled = false
        var requiresExplicitDrainKick = frameInbox.hasPending()
        switch releaseDisposition {
        case .injectCachedFrame:
            if let cachedStartupFrame {
                let injectedFrame = CapturedFrame(
                    pixelBuffer: cachedStartupFrame.pixelBuffer,
                    presentationTime: cachedStartupFrame.presentationTime,
                    duration: cachedStartupFrame.duration,
                    captureTime: cachedStartupFrame.captureTime,
                    info: resolvedStartupFrameInjectionInfo(cachedStartupFrame.info)
                )
                _ = frameInbox.enqueue(injectedFrame)
                requiresExplicitDrainKick = true
                MirageLogger.stream(
                    "Queued cached pre-registration frame for startup stream \(streamID) idle=\(cachedStartupFrame.info.isIdleFrame)"
                )
            }
        case .none:
            break
        }

        shouldEncodeFrames = true
        MirageLogger.signpostEvent(.stream, "Startup.EncodingEnabled", "stream=\(streamID)")
        MirageLogger.stream("UDP registration confirmed, encoding resumed")
        if requiresExplicitDrainKick {
            // A frame enqueued while startup-gated marks the inbox as scheduled even
            // though no drain task is running yet. Kick the first drain explicitly.
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        } else {
            scheduleProcessingIfNeeded()
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        disableStartupTransportProtection()
        typingBurstExpiryTask?.cancel()
        typingBurstExpiryTask = nil

        await stopAllAuxiliaryCaptures()

        await captureEngine?.stopCapture()
        captureEngine = nil
        frameInbox.clear()
        cachedStartupFrame = nil
        startupFrameCachingEnabled = false

        if useVirtualDisplay {
            let expectedOwner: WindowSpaceManager.WindowBindingOwner?
            if windowID != 0 {
                let cachedDisplayID = virtualDisplayContext?.displayID ?? 0
                let cachedGeneration = virtualDisplayContext?.generation ?? 0
                expectedOwner = WindowSpaceManager.WindowBindingOwner(
                    streamID: streamID,
                    windowID: windowID,
                    displayID: cachedDisplayID,
                    generation: cachedGeneration
                )
            } else {
                expectedOwner = nil
            }
            await WindowSpaceManager.shared.restoreWindowSilently(
                windowID,
                expectedOwner: expectedOwner
            )
            await SharedVirtualDisplayManager.shared.releaseAppStreamDisplay()
            virtualDisplayContext = nil
            virtualDisplayVisibleBounds = .zero
            virtualDisplayCaptureSourceRect = .zero
            virtualDisplayCapturePresentationRect = .zero
            virtualDisplayVisiblePixelResolution = .zero
        }
        useVirtualDisplay = false

        await packetSender?.stop()
        packetSender = nil

        await encoder?.stopEncoding()

        encoder = nil
        trafficLightMaskGeometryCache = nil
        isAppStream = false
        applicationProcessID = 0

        MirageLogger.stream("Stopped stream \(streamID)")
    }
}

#endif
