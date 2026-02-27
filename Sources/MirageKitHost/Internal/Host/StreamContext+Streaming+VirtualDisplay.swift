//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display streaming paths.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    private struct VirtualDisplayPlacement: Sendable {
        let snapshot: SharedVirtualDisplayManager.DisplaySnapshot
        let visibleBounds: CGRect
        let captureSourceRect: CGRect
        let visiblePixelResolution: CGSize
        let insetsPixels: CGSize
    }

    enum VirtualDisplayResizeError: LocalizedError {
        case rollbackFailed(streamID: StreamID, reason: String)

        var errorDescription: String? {
            switch self {
            case let .rollbackFailed(streamID, reason):
                "Virtual display resize rollback failed for stream \(streamID): \(reason)"
            }
        }
    }

    func startWithVirtualDisplay(
        windowWrapper _: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientDisplayResolution: CGSize,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void,
        onVirtualDisplayReady: @escaping @Sendable (SharedVirtualDisplayManager.DisplaySnapshot, CGRect) async -> Void = {
            _, _ in
        }
    )
        async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true
        // Keep the virtual display at the target refresh so capture stays aligned.
        let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate)
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let application = applicationWrapper.application
        applicationProcessID = application.processID

        onEncodedPacket = onEncodedFrame
        self.onContentBoundsChanged = onContentBoundsChanged
        self.onNewWindowDetected = onNewWindowDetected
        let packetSender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onEncodedFrame: onEncodedFrame
        )
        self.packetSender = packetSender
        await packetSender.start()
        await packetSender.setTargetBitrateBps(encoderConfig.bitrate)

        MirageLogger
            .stream(
                "Starting stream \(streamID) with dedicated virtual display at \(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height))"
            )

        let placement = try await configureDedicatedVirtualDisplay(
            requestedVisibleResolution: clientDisplayResolution,
            refreshRate: virtualDisplayRefreshRate,
            isUpdate: false
        )
        let vdContext = placement.snapshot
        virtualDisplayContext = vdContext

        await onVirtualDisplayReady(vdContext, placement.visibleBounds)

        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdContext.spaceID,
            displayID: vdContext.displayID,
            displayBounds: placement.visibleBounds,
            targetContentAspectRatio: requestedAspectRatioForWindowFit(
                requestedPixelResolution: clientDisplayResolution,
                visiblePixelResolution: placement.visiblePixelResolution,
                displayPixelResolution: placement.snapshot.resolution
            ),
            owner: WindowSpaceManager.WindowBindingOwner(
                streamID: streamID,
                windowID: windowID,
                displayID: vdContext.displayID,
                generation: vdContext.generation
            )
        )

        let resolvedDisplayWrapper = try await resolveVirtualDisplayDisplay(
            displayID: vdContext.displayID,
            label: "virtual display start"
        )

        let resolvedDisplayID = resolvedDisplayWrapper.display.displayID
        if !CGVirtualDisplayBridge.isMirageDisplay(resolvedDisplayID) {
            MirageLogger.error(.stream, "Expected virtual display capture, got display \(resolvedDisplayID)")
        }
        MirageLogger
            .stream(
                "Resolved display capture target \(resolvedDisplayID) sourceRect=\(placement.captureSourceRect)"
            )

        applyVirtualDisplayPlacementState(placement)
        baseCaptureSize = placement.visiblePixelResolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        lastWindowFrame = placement.visibleBounds
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Virtual display init")
        MirageLogger
            .stream(
                "Virtual display init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
            )
        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger
            .encoder(
                "Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (visible target \(Int(baseCaptureSize.width))x\(Int(baseCaptureSize.height)))"
            )

        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        let streamID = streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
                guard let self else { return }

                // Dedicated app-stream virtual displays already capture an explicit sourceRect
                // that matches the intended viewport. Using per-frame SCK content rect metadata
                // here can reintroduce stale/incorrect crop regions and cause client-side
                // underfill on external-display paths. Pin packet contentRect to full frame.
                let contentRect = CGRect(
                    x: 0,
                    y: 0,
                    width: outputSize.width,
                    height: outputSize.height
                )
                let frameNum = localFrameNumber
                let seqStart = localSequenceNumber

                let now = CFAbsoluteTimeGetCurrent()
                let fecBlockSize = resolvedFECBlockSize(isKeyframe: isKeyframe, now: now)
                let frameByteCount = encodedData.count
                let dataFragments = (frameByteCount + maxPayloadSize - 1) / maxPayloadSize
                let parityFragments = fecBlockSize > 1 ? (dataFragments + fecBlockSize - 1) / fecBlockSize : 0
                let totalFragments = dataFragments + parityFragments
                let wireBytes = frameByteCount + parityFragments * maxPayloadSize
                localSequenceNumber += UInt32(totalFragments)
                localFrameNumber += 1

                let flags = baseFrameFlags.union(dynamicFrameFlags)
                let dimToken = dimensionToken
                let epoch = epoch

                let generation = packetSender.currentGenerationSnapshot()
                if isKeyframe {
                    Task(priority: .userInitiated) {
                        await self.markKeyframeInFlight()
                        await self.markKeyframeSent()
                    }
                }
                let workItem = StreamPacketSender.WorkItem(
                    encodedData: encodedData,
                    frameByteCount: frameByteCount,
                    isKeyframe: isKeyframe,
                    presentationTime: presentationTime,
                    contentRect: contentRect,
                    streamID: streamID,
                    frameNumber: frameNum,
                    sequenceNumberStart: seqStart,
                    additionalFlags: flags,
                    dimensionToken: dimToken,
                    epoch: epoch,
                    fecBlockSize: fecBlockSize,
                    wireBytes: wireBytes,
                    logPrefix: "VD Frame",
                    generation: generation,
                    onSendStart: nil,
                    onSendComplete: nil
                )
                packetSender.enqueue(workItem)
            }, onFrameComplete: { [weak self] in
                Task(priority: .userInitiated) { await self?.finishEncoding() }
            }
        )

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: true
        )
        captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startDisplayCapture(
            display: resolvedDisplayWrapper.display,
            resolution: outputSize,
            sourceRect: placement.captureSourceRect,
            contentWindowID: windowID,
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger
            .stream("Started stream \(streamID) with virtual display \(vdContext.displayID) for window \(windowID)")
    }

    func updateVirtualDisplayResolution(newResolution: CGSize) async throws {
        guard isRunning, useVirtualDisplay else { return }
        let requestedPixels = sanitizePixelResolution(newResolution)
        let currentVisiblePixels = virtualDisplayVisiblePixelResolution == .zero
            ? baseCaptureSize
            : virtualDisplayVisiblePixelResolution
        let currentDisplayPixels = virtualDisplayContext?.resolution ?? .zero

        // Client drawable/layout updates can produce repeated display-size notifications with
        // effectively unchanged visible resolution. Reconfiguring the dedicated virtual display
        // in that case can introduce avoidable capture restarts and transient blank frames.
        let visibleMatches = currentVisiblePixels != .zero &&
            isResolutionMatch(currentVisiblePixels, requestedPixels, tolerance: 4.0)
        let displayMatches = currentDisplayPixels != .zero &&
            isResolutionMatch(currentDisplayPixels, requestedPixels, tolerance: 4.0)
        if visibleMatches || displayMatches {
            let matchedResolution = if displayMatches { currentDisplayPixels } else { currentVisiblePixels }
            MirageLogger
                .stream(
                    "Skipping dedicated virtual display update for stream \(streamID): requested size unchanged (\(Int(matchedResolution.width))x\(Int(matchedResolution.height)))"
                )
            return
        }

        let previousDisplaySnapshot = virtualDisplayContext
        let previousVisibleBounds = virtualDisplayVisibleBounds
        let previousCaptureSourceRect = virtualDisplayCaptureSourceRect
        let previousVisiblePixelResolution = virtualDisplayVisiblePixelResolution
        let previousBaseCaptureSize = baseCaptureSize
        let previousCaptureSize = currentCaptureSize
        let previousEncodedSize = currentEncodedSize
        let previousLastWindowFrame = lastWindowFrame
        let previousStreamScale = streamScale

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        advanceEpoch(reason: "virtual display resize")
        await packetSender?.bumpGeneration(reason: "virtual display resize")
        await packetSender?.resetQueue(reason: "virtual display resize")
        resetPipelineStateForReconfiguration(reason: "virtual display resize")

        MirageLogger
            .stream(
                "Updating dedicated virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)"
            )

        await captureEngine?.stopCapture()
        do {
            let placement = try await configureDedicatedVirtualDisplay(
                requestedVisibleResolution: requestedPixels,
                refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate),
                isUpdate: true
            )
            let newContext = placement.snapshot
            virtualDisplayContext = newContext
            applyVirtualDisplayPlacementState(placement)

            try await WindowSpaceManager.shared.moveWindow(
                windowID,
                toSpaceID: newContext.spaceID,
                displayID: newContext.displayID,
                displayBounds: placement.visibleBounds,
                targetContentAspectRatio: requestedAspectRatioForWindowFit(
                    requestedPixelResolution: requestedPixels,
                    visiblePixelResolution: placement.visiblePixelResolution,
                    displayPixelResolution: placement.snapshot.resolution
                ),
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: streamID,
                    windowID: windowID,
                    displayID: newContext.displayID,
                    generation: newContext.generation
                )
            )

            let resolvedDisplayWrapper = try await resolveVirtualDisplayDisplay(
                displayID: newContext.displayID,
                label: "virtual display update"
            )

            baseCaptureSize = placement.visiblePixelResolution
            streamScale = resolvedStreamScale(
                for: baseCaptureSize,
                requestedScale: requestedStreamScale,
                logLabel: "Resolution cap"
            )
            let outputSize = scaledOutputSize(for: baseCaptureSize)
            currentCaptureSize = outputSize
            currentEncodedSize = outputSize
            captureMode = .display
            lastWindowFrame = placement.visibleBounds
            updateQueueLimits()
            if let encoder {
                try await encoder.updateDimensions(
                    width: Int(outputSize.width),
                    height: Int(outputSize.height)
                )
                try await encoder.reset()
                let resolvedPixelFormat = await encoder.getActivePixelFormat()
                activePixelFormat = resolvedPixelFormat
                MirageLogger
                    .encoder("Encoder updated to \(Int(outputSize.width))x\(Int(outputSize.height)) for resolution change")
            }

            await applyDerivedQuality(for: outputSize, logLabel: "Virtual display resize")

            let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: activePixelFormat)
            let windowCaptureEngine = WindowCaptureEngine(
                configuration: captureConfig,
                capturePressureProfile: capturePressureProfile,
                latencyMode: latencyMode,
                captureFrameRate: captureFrameRate,
                usesDisplayRefreshCadence: true
            )
            captureEngine = windowCaptureEngine

            try await windowCaptureEngine.startDisplayCapture(
                display: resolvedDisplayWrapper.display,
                resolution: outputSize,
                sourceRect: placement.captureSourceRect,
                contentWindowID: windowID,
                showsCursor: false,
                onFrame: { [weak self] frame in
                    self?.enqueueCapturedFrame(frame)
                },
                onAudio: onCapturedAudioBuffer
            )
            await refreshCaptureCadence()

            await encoder?.forceKeyframe()

            MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
        } catch {
            let originalErrorDescription = error.localizedDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let previousDisplaySnapshot {
                virtualDisplayContext = previousDisplaySnapshot
                virtualDisplayVisibleBounds = previousVisibleBounds
                virtualDisplayCaptureSourceRect = previousCaptureSourceRect
                virtualDisplayVisiblePixelResolution = previousVisiblePixelResolution
            }
            baseCaptureSize = previousBaseCaptureSize
            streamScale = previousStreamScale
            currentCaptureSize = previousCaptureSize
            currentEncodedSize = previousEncodedSize
            captureMode = .display
            lastWindowFrame = previousLastWindowFrame
            updateQueueLimits()

            // Best-effort rollback: restore the pre-resize capture pipeline so a failed
            // resize does not leave the stream black until full teardown.
            var rollbackRestoredCapture = false
            if let previousDisplaySnapshot,
               previousCaptureSourceRect.width > 0,
               previousCaptureSourceRect.height > 0 {
                do {
                    let previousDisplayWrapper = try await resolveVirtualDisplayDisplay(
                        displayID: previousDisplaySnapshot.displayID,
                        label: "virtual display update rollback",
                        maxAttempts: 4,
                        initialDelayMs: 40
                    )
                    let rollbackCaptureSize = if previousCaptureSize.width > 0, previousCaptureSize.height > 0 {
                        previousCaptureSize
                    } else {
                        previousEncodedSize
                    }
                    let rollbackConfig = encoderConfig.withInternalOverrides(pixelFormat: activePixelFormat)
                    let rollbackEngine = WindowCaptureEngine(
                        configuration: rollbackConfig,
                        capturePressureProfile: capturePressureProfile,
                        latencyMode: latencyMode,
                        captureFrameRate: captureFrameRate,
                        usesDisplayRefreshCadence: true
                    )
                    captureEngine = rollbackEngine
                    try await rollbackEngine.startDisplayCapture(
                        display: previousDisplayWrapper.display,
                        resolution: rollbackCaptureSize,
                        sourceRect: previousCaptureSourceRect,
                        contentWindowID: windowID,
                        showsCursor: false,
                        onFrame: { [weak self] frame in
                            self?.enqueueCapturedFrame(frame)
                        },
                        onAudio: onCapturedAudioBuffer
                    )
                    await refreshCaptureCadence()
                    await encoder?.forceKeyframe()
                    rollbackRestoredCapture = true
                    MirageLogger.stream(
                        "Virtual display resize failed; restored previous capture pipeline for stream \(streamID)"
                    )
                } catch let rollbackError {
                    MirageLogger.error(
                        .stream,
                        error: rollbackError,
                        message: "Failed to restore previous capture pipeline after resize failure: "
                    )
                }
            }

            if rollbackRestoredCapture {
                throw error
            }
            let renderedReason = originalErrorDescription.isEmpty ? String(describing: error) : originalErrorDescription
            throw VirtualDisplayResizeError.rollbackFailed(streamID: streamID, reason: renderedReason)
        }
    }

    private func resolveVirtualDisplayDisplay(
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 8,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let display = content.displays.first(where: { $0.displayID == displayID }) {
                    if attempt > 1 {
                        MirageLogger.stream("Resolved virtual display \(displayID) on attempt \(attempt) (\(label))")
                    }
                    return SCDisplayWrapper(display: display)
                }

                if attempt < attempts {
                    MirageLogger
                        .stream(
                            "Virtual display \(displayID) not yet in SCShareableContent on attempt \(attempt)/\(attempts) (\(label)); retrying in \(delayMs)ms"
                        )
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                }
            } catch {
                if attempt >= attempts { throw error }
                MirageLogger.error(
                    .stream,
                    "Failed to query SCShareableContent for display \(displayID) (\(label)) attempt \(attempt)/\(attempts): \(error)"
                )
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        throw MirageError.protocolError("Unable to resolve virtual display \(displayID) for stream \(streamID) (\(label))")
    }

    private func configureDedicatedVirtualDisplay(
        requestedVisibleResolution: CGSize,
        refreshRate: Int,
        isUpdate: Bool
    )
    async throws -> VirtualDisplayPlacement {
        let requestedPixels = sanitizePixelResolution(requestedVisibleResolution)
        let colorSpace = encoderConfig.colorSpace
        let scaleHint = max(1.0, virtualDisplayContext?.scaleFactor ?? 2.0)
        let cachedInsets = await SharedVirtualDisplayManager.shared.cachedDedicatedInsetsPixels(
            scaleFactor: scaleHint,
            colorSpace: colorSpace
        )
        let initialDisplayPixels: CGSize = if isUpdate {
            sanitizePixelResolution(
                CGSize(
                    width: requestedPixels.width + cachedInsets.width,
                    height: requestedPixels.height + cachedInsets.height
                )
            )
        } else {
            // Fresh app-window starts should prefer the client-requested display size.
            // Inset expansion can over-constrain some app windows and cause startup misses.
            requestedPixels
        }

        func applyDisplayResolution(_ resolution: CGSize) async throws -> SharedVirtualDisplayManager.DisplaySnapshot {
            if isUpdate {
                return try await SharedVirtualDisplayManager.shared.updateDedicatedDisplay(
                    for: streamID,
                    newResolution: resolution,
                    refreshRate: refreshRate
                )
            }
            return try await SharedVirtualDisplayManager.shared.acquireDedicatedDisplay(
                for: streamID,
                resolution: resolution,
                refreshRate: refreshRate,
                colorSpace: colorSpace
            )
        }

        var snapshot: SharedVirtualDisplayManager.DisplaySnapshot
        do {
            snapshot = try await applyDisplayResolution(initialDisplayPixels)
        } catch {
            let usedInsetExpansion = !isResolutionMatch(initialDisplayPixels, requestedPixels, tolerance: 1.0)
            guard usedInsetExpansion else { throw error }
            MirageLogger.stream(
                "Dedicated display allocation failed with inset-expanded resolution \(Int(initialDisplayPixels.width))x\(Int(initialDisplayPixels.height)); retrying requested resolution \(Int(requestedPixels.width))x\(Int(requestedPixels.height))"
            )
            snapshot = try await applyDisplayResolution(requestedPixels)
        }

        var placement = await resolveVirtualDisplayPlacement(from: snapshot)
        await cacheObservedDedicatedInsets(for: placement, colorSpace: colorSpace)
        MirageLogger.stream(
            "Virtual display calibration (initial) stream \(streamID): requested=\(Int(requestedPixels.width))x\(Int(requestedPixels.height)), display=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height)), scale=\(placement.snapshot.scaleFactor)"
        )
        func hasDirectVisibleMatch(_ currentPlacement: VirtualDisplayPlacement) -> Bool {
            isResolutionMatch(currentPlacement.visiblePixelResolution, requestedPixels, tolerance: 2.0)
        }

        func hasInsetAdjustedMatch(_ currentPlacement: VirtualDisplayPlacement) -> Bool {
            let insetAdjustedVisible = CGSize(
                width: currentPlacement.visiblePixelResolution.width + currentPlacement.insetsPixels.width,
                height: currentPlacement.visiblePixelResolution.height + currentPlacement.insetsPixels.height
            )
            return isResolutionMatch(insetAdjustedVisible, requestedPixels, tolerance: 2.0)
        }

        if hasDirectVisibleMatch(placement) {
            return placement
        }
        var canFallbackToInsetAdjustedPlacement = hasInsetAdjustedMatch(placement)
        if canFallbackToInsetAdjustedPlacement, placement.snapshot.scaleFactor >= 1.5 {
            MirageLogger.stream(
                "Virtual display calibration keeping inset-adjusted Retina placement for stream \(streamID): visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), requested=\(Int(requestedPixels.width))x\(Int(requestedPixels.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height)), scale=\(placement.snapshot.scaleFactor)"
            )
            return placement
        }
        if canFallbackToInsetAdjustedPlacement {
            MirageLogger.stream(
                "Virtual display calibration found inset-adjusted match for stream \(streamID); attempting correction toward direct visible match"
            )
        }

        let maxCorrectionAttempts = 3
        var correctionAttempts = 0

        while correctionAttempts < maxCorrectionAttempts {
            let correction = CGSize(
                width: requestedPixels.width - placement.visiblePixelResolution.width,
                height: requestedPixels.height - placement.visiblePixelResolution.height
            )
            let correctedResolution = sanitizePixelResolution(
                CGSize(
                    width: placement.snapshot.resolution.width + correction.width,
                    height: placement.snapshot.resolution.height + correction.height
                )
            )
            guard !isResolutionMatch(correctedResolution, placement.snapshot.resolution, tolerance: 1.0) else { break }

            correctionAttempts += 1
            do {
                snapshot = try await SharedVirtualDisplayManager.shared.updateDedicatedDisplay(
                    for: streamID,
                    newResolution: correctedResolution,
                    refreshRate: refreshRate
                )
            } catch {
                if canFallbackToInsetAdjustedPlacement {
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                    let refreshedPlacement = await resolveVirtualDisplayPlacement(from: snapshot)
                    await cacheObservedDedicatedInsets(for: refreshedPlacement, colorSpace: colorSpace)
                    if hasDirectVisibleMatch(refreshedPlacement) {
                        MirageLogger.stream(
                            "Virtual display correction attempt \(correctionAttempts) failed for stream \(streamID); using refreshed placement with direct visible match (error: \(renderedDetail))"
                        )
                        return refreshedPlacement
                    }
                    if hasInsetAdjustedMatch(refreshedPlacement) {
                        MirageLogger.stream(
                            "Virtual display correction attempt \(correctionAttempts) failed for stream \(streamID); keeping refreshed inset-adjusted placement (error: \(renderedDetail))"
                        )
                        return refreshedPlacement
                    }
                    MirageLogger.stream(
                        "Virtual display correction attempt \(correctionAttempts) failed for stream \(streamID); refreshed placement did not converge, keeping prior inset-adjusted placement (error: \(renderedDetail))"
                    )
                    return placement
                }
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: error) : detail
                throw MirageError.protocolError(
                    "Dedicated virtual display correction attempt \(correctionAttempts) failed for stream \(streamID): \(renderedDetail)"
                )
            }

            placement = await resolveVirtualDisplayPlacement(from: snapshot)
            await cacheObservedDedicatedInsets(for: placement, colorSpace: colorSpace)
            MirageLogger.stream(
                "Virtual display calibration correction #\(correctionAttempts) stream \(streamID): display=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height)), target=\(Int(requestedPixels.width))x\(Int(requestedPixels.height))"
            )

            if hasDirectVisibleMatch(placement) {
                return placement
            }
            if hasInsetAdjustedMatch(placement) {
                canFallbackToInsetAdjustedPlacement = true
            }
        }

        if hasInsetAdjustedMatch(placement) {
            MirageLogger.stream(
                "Virtual display calibration accepted inset-adjusted visible size for stream \(streamID) after \(correctionAttempts) correction attempt(s): visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), requested=\(Int(requestedPixels.width))x\(Int(requestedPixels.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height))"
            )
            return placement
        }

        throw MirageError.protocolError(
            "Virtual display calibration did not converge for stream \(streamID): requestedVisible=\(Int(requestedPixels.width))x\(Int(requestedPixels.height)), finalDisplay=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), finalVisible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), finalInsets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height)), attempts=\(correctionAttempts)"
        )
    }

    private func cacheObservedDedicatedInsets(
        for placement: VirtualDisplayPlacement,
        colorSpace: MirageColorSpace
    ) async {
        await SharedVirtualDisplayManager.shared.cacheDedicatedInsetsPixels(
            placement.insetsPixels,
            scaleFactor: placement.snapshot.scaleFactor,
            colorSpace: colorSpace
        )
    }

    private func applyVirtualDisplayPlacementState(_ placement: VirtualDisplayPlacement) {
        virtualDisplayVisibleBounds = placement.visibleBounds
        virtualDisplayCaptureSourceRect = placement.captureSourceRect
        virtualDisplayVisiblePixelResolution = placement.visiblePixelResolution
    }

    private func resolveVirtualDisplayPlacement(
        from snapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        maxAttempts: Int = 8,
        initialDelayMs: Int = 60
    )
    async -> VirtualDisplayPlacement {
        let attempts = max(1, maxAttempts)
        var delayMs = max(20, initialDelayMs)
        var lastPlacement = computeVirtualDisplayPlacement(from: snapshot)

        for attempt in 1 ... attempts {
            lastPlacement = computeVirtualDisplayPlacement(from: snapshot)
            if CGVirtualDisplayBridge.hasScreen(snapshot.displayID) || attempt == attempts {
                return lastPlacement
            }
            try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
            delayMs = min(400, Int(Double(delayMs) * 1.4))
        }

        return lastPlacement
    }

    private func computeVirtualDisplayPlacement(
        from snapshot: SharedVirtualDisplayManager.DisplaySnapshot
    )
    -> VirtualDisplayPlacement {
        let scaleFactor = max(1.0, snapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: snapshot.resolution,
            scaleFactor: scaleFactor
        )
        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            snapshot.displayID,
            knownResolution: logicalResolution
        )
        var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            visibleBounds = displayBounds
        }

        var captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        if captureSourceRect.isEmpty {
            let localX = visibleBounds.minX - displayBounds.minX
            let localY = visibleBounds.minY - displayBounds.minY
            captureSourceRect = CGRect(
                x: max(0, localX),
                y: max(0, localY),
                width: visibleBounds.width,
                height: visibleBounds.height
            )
        }

        let insets = CGVirtualDisplayBridge.displayInsets(
            displayBounds: displayBounds,
            visibleBounds: visibleBounds
        )
        let insetsPixels = CGSize(
            width: ceil(insets.horizontal * scaleFactor),
            height: ceil(insets.vertical * scaleFactor)
        )
        let visiblePixelResolution = sanitizePixelResolution(
            CGSize(
                width: visibleBounds.width * scaleFactor,
                height: visibleBounds.height * scaleFactor
            )
        )

        return VirtualDisplayPlacement(
            snapshot: snapshot,
            visibleBounds: visibleBounds,
            captureSourceRect: captureSourceRect,
            visiblePixelResolution: visiblePixelResolution,
            insetsPixels: insetsPixels
        )
    }

    private func sanitizePixelResolution(_ resolution: CGSize) -> CGSize {
        CGSize(
            width: max(1, ceil(resolution.width)),
            height: max(1, ceil(resolution.height))
        )
    }

    private func isResolutionMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat = 1.0) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

}

#endif
