//
//  StreamContext+Streaming+Updates.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream update and shutdown helpers.
//

import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
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
        requestedStreamScale = clampedScale
        let previousScale = streamScale

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "stream scale update")
        resetPipelineStateForReconfiguration(reason: "stream scale update")

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
        baseCaptureSize = derivedBaseSize
        guard derivedBaseSize.width > 0, derivedBaseSize.height > 0 else { return }

        let resolvedScale = resolvedStreamScale(
            for: derivedBaseSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        guard resolvedScale != streamScale else { return }
        streamScale = resolvedScale

        let outputSize = scaledOutputSize(for: derivedBaseSize)
        let scaledWidth = Int(outputSize.width)
        let scaledHeight = Int(outputSize.height)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize

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

    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        shouldEncodeFrames = true
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if !startupRegistrationLogged {
            startupRegistrationLogged = true
            logStartupEvent("UDP registration confirmed")
        }

        if let encoder {
            await encoder.resetFrameNumber()
            await encoder.forceKeyframe()
        }

        MirageLogger.stream("UDP registration confirmed, encoding resumed")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        await captureEngine?.stopCapture()
        captureEngine = nil
        frameInbox.clear()

        if useVirtualDisplay {
            await WindowSpaceManager.shared.restoreWindowSilently(windowID)
            await SharedVirtualDisplayManager.shared.releaseDisplay(for: streamID)
            virtualDisplayContext = nil
        }

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
