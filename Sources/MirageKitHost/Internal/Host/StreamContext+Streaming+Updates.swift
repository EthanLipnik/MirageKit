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
        let bitDepthChanged = updated.bitDepth != current.bitDepth
        let bitrateChanged = updated.bitrate != current.bitrate

        guard bitDepthChanged || bitrateChanged else {
            return .noChange
        }
        if bitrateChanged, !bitDepthChanged {
            return .bitrateOnly
        }
        return .fullReconfiguration
    }

    func updateEncoderSettings(
        bitDepth: MirageVideoBitDepth?,
        bitrate: Int?
    ) async throws {
        guard isRunning else { return }

        var updatedConfig = encoderConfig.withOverrides(
            bitDepth: bitDepth,
            bitrate: bitrate
        )
        if let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: updatedConfig.bitrate
        ) {
            updatedConfig.bitrate = normalizedBitrate
        }

        let updateMode = Self.encoderSettingsUpdateMode(
            current: encoderConfig,
            updated: updatedConfig
        )
        guard updateMode != .noChange else { return }

        if updateMode == .bitrateOnly {
            encoderConfig = updatedConfig
            await packetSender?.setTargetBitrateBps(encoderConfig.bitrate)
            await encoder?.updateBitrate(encoderConfig.bitrate)
            if currentEncodedSize != .zero {
                await applyDerivedQuality(for: currentEncodedSize, logLabel: "Bitrate update")
            }
            let bitrateText = encoderConfig.bitrate.map(String.init) ?? "auto"
            MirageLogger.stream("Encoder bitrate update applied: bitrate=\(bitrateText)")
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
                "Encoder settings update applied: bitDepth=\(encoderConfig.bitDepth.displayName), bitrate=\(bitrateText)"
            )
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
        if encoderConfig.bitDepth == .tenBit {
            if isRunning {
                do {
                    try await updateEncoderSettings(
                        bitDepth: .eightBit,
                        bitrate: encoderConfig.bitrate
                    )
                    return true
                } catch {
                    MirageLogger.error(.stream, error: error, message: "Game mode stage 2 bit-depth override failed: ")
                    return false
                }
            }

            encoderConfig = encoderConfig.withOverrides(
                bitDepth: .eightBit,
                bitrate: encoderConfig.bitrate
            )
            activePixelFormat = encoderConfig.pixelFormat
            if currentEncodedSize != .zero {
                await applyDerivedQuality(for: currentEncodedSize, logLabel: "Game mode stage 2")
            }
            MirageLogger.stream("Game mode stage 2 applied without active capture: bitDepth=8-bit")
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
                        bitDepth: nil,
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
        let needsBitDepthRestore = encoderConfig.bitDepth != gameModeBaselineBitDepth
        let needsScaleRestore = abs(streamScale - baselineScale) > 0.001
        guard needsBitDepthRestore || needsScaleRestore else { return false }

        if isRunning {
            do {
                if needsBitDepthRestore {
                    try await updateEncoderSettings(
                        bitDepth: gameModeBaselineBitDepth,
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

        if needsBitDepthRestore {
            encoderConfig = encoderConfig.withOverrides(
                bitDepth: gameModeBaselineBitDepth,
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
            "Game mode stage 2 restored without active capture: bitDepth=\(gameModeBaselineBitDepth.displayName), " +
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
                        bitDepth: nil,
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

        if let captureEngine { try await captureEngine.updateDimensions(windowFrame: windowFrame, outputScale: streamScale) }

        if let encoder { try await encoder.updateDimensions(width: width, height: height) }
        await applyDerivedQuality(for: outputSize, logLabel: "Dimension update")

        await encoder?.forceKeyframe()

        MirageLogger.stream("Dimension update complete (frames resumed)")
    }

    func updateResolution(width: Int, height: Int) async throws {
        guard isRunning else { return }

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

        if let captureEngine { try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight) }

        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        updateQueueLimits()

        if let encoder {
            try await encoder.updateDimensions(width: scaledWidth, height: scaledHeight)
            updateQueueLimits()
        }

        await encoder?.forceKeyframe()

        MirageLogger.stream("Resolution update to \(scaledWidth)x\(scaledHeight) complete (frames resumed)")
    }

    func updateStreamScale(_ newScale: CGFloat) async throws {
        let clampedScale = StreamContext.clampStreamScale(newScale)
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

        if let captureEngine {
            switch captureMode {
            case .display:
                try await captureEngine.updateResolution(width: scaledWidth, height: scaledHeight)
            case .window:
                if !lastWindowFrame.isEmpty { try await captureEngine.updateDimensions(windowFrame: lastWindowFrame, outputScale: streamScale) }
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
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()
        await applyDerivedQuality(for: outputSize, logLabel: "Desktop resize reset")
        await encoder.forceKeyframe()
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

    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        shouldEncodeFrames = true
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if !startupRegistrationLogged {
            startupRegistrationLogged = true
            logStartupEvent("UDP registration confirmed")
        }
        noteLossEvent(reason: "UDP registration warmup", enablePFrameFEC: true)

        if let encoder {
            await encoder.resetFrameNumber()
            await encoder.forceKeyframe()
        }

        MirageLogger.stream("UDP registration confirmed, encoding resumed")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        typingBurstExpiryTask?.cancel()
        typingBurstExpiryTask = nil

        await captureEngine?.stopCapture()
        captureEngine = nil
        frameInbox.clear()

        if useVirtualDisplay {
            await WindowSpaceManager.shared.restoreWindowSilently(windowID)
            await SharedVirtualDisplayManager.shared.releaseDedicatedDisplay(for: streamID)
            virtualDisplayContext = nil
        }
        useVirtualDisplay = false

        await packetSender?.stop()
        packetSender = nil

        await encoder?.stopEncoding()

        encoder = nil
        onEncodedPacket = nil
        onContentBoundsChanged = nil
        onNewWindowDetected = nil

        MirageLogger.stream("Stopped stream \(streamID)")
    }
}

#endif
