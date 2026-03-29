//
//  MirageHostService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Desktop Streaming

extension MirageHostService {
    /// Start streaming the desktop (mirrored or secondary display mode)
    /// This stops any active app/window streams for mutual exclusivity
    func startDesktopStream(
        to clientContext: ClientContext,
        displayResolution: CGSize,
        clientScaleFactor: CGFloat? = nil,
        mode: MirageDesktopStreamMode,
        keyFrameInterval: Int?,
        colorDepth: MirageStreamColorDepth?,
        captureQueueDepth: Int?,
        bitrate: Int?,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        performanceMode: MirageStreamPerformanceMode = .standard,
        allowRuntimeQualityAdjustment: Bool?,
        lowLatencyHighResolutionCompressionBoost: Bool,
        temporaryDegradationMode: MirageTemporaryDegradationMode = .off,
        disableResolutionCap: Bool,
        streamScale: CGFloat?,
        audioConfiguration: MirageAudioConfiguration,
        targetFrameRate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil
    )
    async throws {
        // Check if desktop stream is already active
        guard desktopStreamContext == nil else {
            MirageLogger.host("Desktop stream already active")
            return
        }
        guard mediaSecurityByClientID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for desktop stream client")
        }

        let desktopStartTime = CFAbsoluteTimeGetCurrent()
        func logDesktopStartStep(_ step: String) {
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStartTime) * 1000)
            MirageLogger.host("Desktop start: \(step) (+\(deltaMs)ms)")
        }

        let resolvedClientScaleFactor: CGFloat? = if let clientScaleFactor, clientScaleFactor > 0 {
            max(1.0, clientScaleFactor)
        } else {
            nil
        }
        let clampedStreamScale = StreamContext.clampStreamScale(streamScale ?? 1.0)
        let defaultDesktopBackingScale = resolvedClientScaleFactor ?? max(1.0, sharedVirtualDisplayScaleFactor)
        let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(
            for: targetFrameRate ?? 60
        )
        let resolvedColorDepth = effectiveColorDepth(for: colorDepth)
        if let colorDepth, let resolvedColorDepth, colorDepth != resolvedColorDepth {
            MirageLogger.host(
                "Desktop color depth request downgraded: requested=\(colorDepth.displayName), effective=\(resolvedColorDepth.displayName)"
            )
        }
        let virtualDisplayStartupPlan = desktopVirtualDisplayStartupPlan(
            logicalResolution: displayResolution,
            requestedScaleFactor: defaultDesktopBackingScale,
            requestedRefreshRate: virtualDisplayRefreshRate,
            requestedColorDepth: resolvedColorDepth ?? encoderConfig.colorDepth,
            requestedColorSpace: encoderConfig.withOverrides(
                keyFrameInterval: keyFrameInterval,
                colorDepth: resolvedColorDepth,
                captureQueueDepth: captureQueueDepth,
                bitrate: bitrate
            ).withTargetFrameRate(targetFrameRate ?? encoderConfig.targetFrameRate).colorSpace
        )
        let virtualDisplayStartupAttempts = virtualDisplayStartupPlan.attempts
        let desktopBackingScale = virtualDisplayStartupAttempts.first?.backingScale ??
            resolvedDesktopBackingScaleResolution(
                logicalResolution: displayResolution,
                defaultScaleFactor: defaultDesktopBackingScale
            )
        let virtualDisplayResolution = desktopBackingScale.pixelResolution
        if let resolvedClientScaleFactor {
            let scaleText = Double(resolvedClientScaleFactor).formatted(.number.precision(.fractionLength(3)))
            MirageLogger.host("Desktop stream client scale factor: \(scaleText)x")
        }
        MirageLogger
            .host(
                "Starting desktop stream at " +
                    "\(Int(displayResolution.width))x\(Int(displayResolution.height)) pts " +
                    "(\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px) " +
                    "(\(mode.displayName))"
            )
        logDesktopStartStep("request accepted")

        // Stop all active app/window streams (mutual exclusivity)
        await stopAllStreamsForDesktopMode()
        logDesktopStartStep("other streams stopped")

        // Cancel any in-flight app icon/list streaming immediately so control-channel
        // bandwidth stays available for interactive desktop input and state updates.
        await syncAppListRequestDeferralForInteractiveWorkload()

        // Clear any stuck modifiers from previous streams
        inputController.clearAllModifiers()
        desktopStreamMode = mode
        resetDesktopResizeTransactionState()

        // Configure encoder with optional overrides
        var config = encoderConfig
        config = config.withOverrides(
            keyFrameInterval: keyFrameInterval,
            colorDepth: resolvedColorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )

        if let codec {
            config.codec = codec
        }

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: config.bitrate
        ) {
            config.bitrate = normalized
        }

        // Switch to BGRA pixel format when client requests MetalFX upscaling.
        // MetalFX is incompatible with ProRes pixel formats.
        if let upscalingMode, upscalingMode != .off, codec != .proRes4444 {
            config.applyUpscalingPixelFormat()
            MirageLogger.host("Applying BGRA pixel format for MetalFX \(upscalingMode.displayName) upscaling (desktop stream)")
        }

        if let targetFrameRate { config = config.withTargetFrameRate(targetFrameRate) }
        if disableResolutionCap {
            MirageLogger.host("Desktop stream resolution cap disabled")
        }
        MirageLogger.host("Desktop stream latency mode: \(latencyMode.displayName)")
        MirageLogger.host("Desktop temporary degradation mode: \(temporaryDegradationMode.displayName)")

        if clampedStreamScale < 1.0 {
            MirageLogger.host(
                "Desktop scale \(clampedStreamScale) → capture/encoder downscale; virtual display stays at " +
                    "\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px"
            )
        }
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = if performanceMode == .game {
            .tuned
        } else if temporaryDegradationMode != .off {
            .tuned
        } else {
            resolvedDesktopCapturePressureProfile()
        }
        MirageLogger.host(
            "Desktop capture pressure profile: \(capturePressureProfile.rawValue)"
        )

        // Wake the display if sleeping — the display subsystem must be active
        // for virtual display creation and CGDisplayConfiguration to succeed.
        PowerAssertionManager.wakeDisplay()

        // Acquire virtual display at the resolved streaming resolution.
        // The 5K cap is applied at the encoding layer, not the virtual display.
        // Pass the target frame rate to enable 120Hz when appropriate.
        var acquiredCaptureContext: (
            display: SCDisplayWrapper,
            resolution: CGSize,
            p3CoverageStatus: MirageDisplayP3CoverageStatus?,
            colorSpace: MirageColorSpace?
        )?
        var lastVirtualDisplayError: Error?
        let acquisitionDeadline = ContinuousClock.now + .seconds(20)

        acquisitionLoop: for (index, attempt) in virtualDisplayStartupAttempts.enumerated() {
            if ContinuousClock.now >= acquisitionDeadline {
                MirageLogger.error(.host, "Desktop virtual display acquisition deadline exceeded (20s)")
                break acquisitionLoop
            }

            // Abort early if the client disconnected during acquisition to avoid
            // creating virtual displays that will be immediately destroyed.
            if disconnectingClientIDs.contains(clientContext.client.id)
                || clientsByID[clientContext.client.id] == nil {
                MirageLogger.host("Desktop stream client disconnected during acquisition loop; aborting")
                await cleanupFailedDesktopStreamStartup(mode: mode)
                throw MirageError.protocolError("Desktop stream client disconnected during startup")
            }

            let attemptConfig = config.withInternalOverrides(colorSpace: attempt.colorSpace)
            let attemptResolution = attempt.backingScale.pixelResolution
            let isFinalAttempt = index == virtualDisplayStartupAttempts.count - 1

            if attempt.isCachedTarget {
                MirageLogger.host(
                    "Retrying desktop virtual display acquisition with cached startup target: " +
                        "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                        "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName)"
                )
            } else if attempt.isConservativeRetry {
                MirageLogger.host(
                    "Retrying desktop virtual display acquisition with conservative settings: " +
                        "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                        "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName), 1x backing"
                )
            }

            do {
                let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                    .desktopStream,
                    resolution: attemptResolution,
                    refreshRate: attempt.refreshRate,
                    colorSpace: attempt.colorSpace
                )
                config = attemptConfig
                logDesktopStartStep("virtual display acquired (\(context.displayID), \(attempt.label))")

                let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
                logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
                let captureResolution = context.resolution
                let captureDisplayP3CoverageStatus = context.displayP3CoverageStatus
                let captureDisplayColorSpace = context.colorSpace

                desktopVirtualDisplayID = context.displayID
                var resolvedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds()
                if resolvedBounds == nil { resolvedBounds = resolveDesktopDisplayBounds() }
                guard let bounds = resolvedBounds else {
                    throw MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
                }
                desktopDisplayBounds = bounds
                sharedVirtualDisplayGeneration = await SharedVirtualDisplayManager.shared.getDisplayGeneration()
                sharedVirtualDisplayScaleFactor = max(1.0, context.scaleFactor)
                logDesktopStartStep("display bounds cached")

                if desktopPrimaryPhysicalDisplayID == nil {
                    let primaryDisplayID = resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
                    desktopPrimaryPhysicalDisplayID = primaryDisplayID
                    desktopPrimaryPhysicalBounds = CGDisplayBounds(primaryDisplayID)
                    MirageLogger
                        .host(
                            "Desktop primary physical display: \(primaryDisplayID), bounds=\(desktopPrimaryPhysicalBounds ?? .zero)"
                        )
                }

                if mode == .mirrored {
                    await setupDisplayMirroring(targetDisplayID: context.displayID)
                    logDesktopStartStep("display mirroring configured")
                } else {
                    logDesktopStartStep("display mirroring skipped (secondary display)")
                }

                if captureDisplay.display.displayID != context.displayID {
                    MirageLogger.error(
                        .host,
                        "Desktop capture display mismatch: capture=\(captureDisplay.display.displayID), virtual=\(context.displayID)"
                    )
                }
                if context.colorSpace != config.colorSpace {
                    MirageLogger.host(
                        "Desktop display color space adjusted by virtual display manager: requested=\(config.colorSpace.displayName), effective=\(context.colorSpace.displayName), coverage=\(context.displayP3CoverageStatus.rawValue)"
                    )
                }
                if attempt.isCachedTarget {
                    MirageLogger.host(
                        "Desktop virtual display cached startup target succeeded for stream startup"
                    )
                } else if attempt.isConservativeRetry {
                    MirageLogger.host(
                        "Desktop virtual display conservative retry succeeded for stream startup"
                    )
                }
                MirageLogger
                    .host(
                        "Desktop capture source: Virtual Display (capture display \(captureDisplay.display.displayID), virtual \(context.displayID), requestedColor=\(config.colorSpace.displayName), effectiveColor=\(context.colorSpace.displayName), coverage=\(context.displayP3CoverageStatus.rawValue))"
                    )
                acquiredCaptureContext = (
                    display: captureDisplay,
                    resolution: captureResolution,
                    p3CoverageStatus: captureDisplayP3CoverageStatus,
                    colorSpace: captureDisplayColorSpace
                )
                recordDesktopVirtualDisplayStartupTargetSuccess(
                    attempt,
                    for: virtualDisplayStartupPlan.request
                )
                break acquisitionLoop
            } catch {
                await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
                desktopVirtualDisplayID = nil
                sharedVirtualDisplayGeneration = 0
                sharedVirtualDisplayScaleFactor = 1.0
                desktopDisplayBounds = nil
                lastVirtualDisplayError = error

                if attempt.isCachedTarget {
                    clearDesktopVirtualDisplayStartupTarget(for: virtualDisplayStartupPlan.request)
                    MirageLogger.host(
                        "Cached desktop virtual display startup target failed; evicting cached target for current mode"
                    )
                }

                if !isFinalAttempt {
                    MirageLogger.host(
                        "Desktop virtual display acquisition failed for \(attempt.label); retrying: \(error)"
                    )
                    continue
                }

                if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError,
                   case .creationFailed = sharedDisplayError {
                    MirageLogger.host(
                        "Virtual display acquisition failed for desktop stream; fail-closed policy active: \(error)"
                    )
                } else {
                    MirageLogger.error(
                        .host,
                        "Virtual display acquisition failed for desktop stream; fail-closed policy active: \(error)"
                    )
                }
            }
        }

        if let lastVirtualDisplayError, desktopVirtualDisplayID == nil {
            throw MirageError.protocolError(
                "Virtual display acquisition failed for desktop stream: \(lastVirtualDisplayError)"
            )
        }

        guard let acquiredCaptureContext else {
            throw MirageError.protocolError("Desktop stream virtual display acquisition completed without a capture context")
        }
        let captureDisplay = acquiredCaptureContext.display
        let captureResolution = acquiredCaptureContext.resolution
        let captureDisplayP3CoverageStatus = acquiredCaptureContext.p3CoverageStatus
        let captureDisplayColorSpace = acquiredCaptureContext.colorSpace

        guard !disconnectingClientIDs.contains(clientContext.client.id),
              clientsByID[clientContext.client.id] != nil else {
            MirageLogger.host("Desktop stream client disconnected during virtual display acquisition; aborting startup")
            await cleanupFailedDesktopStreamStartup(mode: mode)
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }

        if let captureDisplayColorSpace, captureDisplayColorSpace != config.colorSpace {
            let requestedColorSpace = config.colorSpace
            config = config.withInternalOverrides(colorSpace: captureDisplayColorSpace)
            MirageLogger.host(
                "Desktop stream runtime color state aligned to acquired display context: requested=\(requestedColorSpace.displayName), effective=\(captureDisplayColorSpace.displayName), bitDepth=\(config.bitDepth.rawValue)"
            )
        }

        let computedStreamScale: CGFloat
        if let maxW = encoderMaxWidth, let maxH = encoderMaxHeight, maxW > 0, maxH > 0,
           virtualDisplayResolution.width > 0, virtualDisplayResolution.height > 0 {
            let wScale = CGFloat(maxW) / virtualDisplayResolution.width
            let hScale = CGFloat(maxH) / virtualDisplayResolution.height
            computedStreamScale = max(0.1, min(1.0, min(wScale, hScale)))
        } else {
            computedStreamScale = StreamContext.clampStreamScale(streamScale ?? 1.0)
        }

        let streamID = nextStreamID
        nextStreamID += 1
        streamStartupBaseTimes[streamID] = desktopStartTime
        streamStartupRegistrationLogged.remove(streamID)
        transportSendErrorReported.remove(streamID)
        let streamContext = StreamContext(
            streamID: streamID,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: config,
            streamScale: computedStreamScale,
            requestedAudioChannelCount: audioConfiguration.channelLayout.channelCount,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: nil,
            additionalFrameFlags: [.desktopStream],
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            temporaryDegradationMode: temporaryDegradationMode,
            disableResolutionCap: disableResolutionCap,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
        await streamContext.setStartupBaseTime(desktopStartTime, label: "desktop stream \(streamID)")
        if let captureDisplayP3CoverageStatus {
            await streamContext.setDisplayP3CoverageStatusOverride(captureDisplayP3CoverageStatus)
        }
        logDesktopStartStep("stream context created (\(streamID))")
        MirageLogger.host("Desktop stream performance mode: \(performanceMode.displayName)")
        if performanceMode != .game, allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for desktop stream \(streamID)")
        }
        if performanceMode != .game, !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for desktop stream \(streamID)")
        }
        let metricsClientID = clientContext.client.id
        await streamContext.setMetricsUpdateHandler { [weak self] metrics in
            self?.dispatchControlWork(clientID: metricsClientID) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(clientID: metricsClientID) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Desktop stream metrics"
                    )
                }
            }
        }

        guard !disconnectingClientIDs.contains(clientContext.client.id),
              clientsByID[clientContext.client.id] != nil else {
            MirageLogger.host("Desktop stream client disconnected before stream activation; aborting startup")
            await cleanupFailedDesktopStreamStartup(mode: mode)
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }

        desktopStreamContext = streamContext
        desktopStreamID = streamID
        desktopStreamClientContext = clientContext
        desktopRequestedScaleFactor = desktopBackingScale.scaleFactor
        streamsByID[streamID] = streamContext
        registerTypingBurstRoute(streamID: streamID, context: streamContext)
        await registerStallWindowPointerRoute(streamID: streamID, context: streamContext)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await activateAudioForClient(
            clientID: clientContext.client.id,
            sourceStreamID: streamID,
            configuration: audioConfiguration
        )

        syncSharedClipboardState(reason: "desktop_stream_started")
        await updateLightsOutState()
        let excludedWindows = await resolveLightsOutExcludedWindows()

        // Register for input handling.
        // For mirrored virtual displays, use the aspect-fit content bounds within the
        // physical display so input matches the mirrored content area.
        let mainDisplayBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputBounds = resolvedDesktopInputBounds(
            physicalBounds: mainDisplayBounds,
            virtualResolution: captureResolution
        )
        let desktopWindow = MirageWindow(
            id: 0,
            title: "Desktop",
            application: nil,
            frame: inputBounds,
            isOnScreen: true,
            windowLayer: 0
        )
        inputStreamCacheActor.set(streamID, window: desktopWindow, client: clientContext.client)

        // Enable power assertion
        await PowerAssertionManager.shared.enable()

        // Open Loom video stream for desktop streaming
        do {
            let videoStream = try await clientContext.controlChannel.session.openStream(
                label: "video/\(streamID)"
            )
            loomVideoStreamsByStreamID[streamID] = videoStream
            transportRegistry.registerVideoStream(videoStream, streamID: streamID)
            MirageLogger.host("Opened Loom video stream for desktop stream \(streamID)")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to open Loom video stream for desktop stream \(streamID): "
            )
        }

        // Start streaming the display
        let firstSuccessfulVideoPacketSent = Locked(false)
        try await streamContext.startDesktopDisplay(
            displayWrapper: captureDisplay,
            resolution: captureResolution,
            excludedWindows: excludedWindows,
            onEncodedFrame: { [weak self] packetData, _, releasePacket in
                guard let self else {
                    releasePacket()
                    return
                }
                sendVideoPacketForStream(streamID, data: packetData) { [weak self] error in
                    releasePacket()
                    if error == nil {
                        let shouldMarkFirstPacket = firstSuccessfulVideoPacketSent.withLock { didMark in
                            guard !didMark else { return false }
                            didMark = true
                            return true
                        }
                        if shouldMarkFirstPacket {
                            Task {
                                await HostDesktopStreamTerminationTracker.shared.markDesktopStreamFirstPacketSent(
                                    streamID: streamID
                                )
                            }
                        }
                        return
                    }
                    guard let self, let error else { return }
                    dispatchMainWork {
                        await self.handleVideoSendError(streamID: streamID, error: error)
                    }
                }
            }
        )
        logDesktopStartStep("capture and encoder started")

        // Send stream-started to client BEFORE enabling encoding so the client's
        // controller/reassembler is ready when video packets arrive.
        // (Window streams already follow this order — see MirageHostService+Streams.swift.)
        let dimensionToken = await streamContext.getDimensionToken()
        let startedDisplayResolution = await currentDesktopStartedResolution(fallback: captureResolution)
        let targetFrameRate = await streamContext.getTargetFrameRate()
        let codec = await streamContext.getCodec()
        let startupAttemptID = UUID()
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            width: Int(startedDisplayResolution.width),
            height: Int(startedDisplayResolution.height),
            frameRate: targetFrameRate,
            codec: codec,
            startupAttemptID: startupAttemptID,
            displayCount: 1,
            dimensionToken: dimensionToken
        )
        do {
            registerPendingStartupAttempt(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                clientID: clientContext.client.id,
                kind: .desktop
            )
            try await clientContext.send(.desktopStreamStarted, content: message)
            MirageLogger.signpostEvent(.host, "Startup.StreamStartedSent", "stream=\(streamID) kind=desktop")
            logDesktopStartStep("desktopStreamStarted sent")
        } catch {
            cancelPendingStartupAttempt(streamID: streamID)
            MirageLogger.error(.host, error: error, message: "Failed to send desktopStreamStarted: ")
            logDesktopStartStep("desktopStreamStarted send failed")
        }

        MirageLogger
            .host(
                "Desktop stream started: streamID=\(streamID), resolution=\(Int(startedDisplayResolution.width))x\(Int(startedDisplayResolution.height))"
            )
        await HostDesktopStreamTerminationTracker.shared.markDesktopStreamStarted(
            streamID: streamID,
            requestedPixelResolution: captureResolution
        )
        MirageInstrumentation.record(.hostStreamDesktopStartedPerformanceMode(.init(rawMode: performanceMode.rawValue)))
    }

    /// Clean up virtual display and mirroring state after a failed desktop stream startup.
    private func cleanupFailedDesktopStreamStartup(mode: MirageDesktopStreamMode) async {
        if let vdID = desktopVirtualDisplayID {
            if mode == .mirrored {
                await disableDisplayMirroring(displayID: vdID)
            }
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        }
        desktopVirtualDisplayID = nil
        desktopDisplayBounds = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = 1.0
        mirroredDesktopDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
    }

    /// Stop the desktop stream
    func stopDesktopStream(reason: DesktopStreamStopReason = .clientRequested) async {
        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        guard let streamID = desktopStreamID else {
            await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
            return
        }

        cancelPendingStartupAttempt(streamID: streamID)
        MirageLogger.host("Stopping desktop stream: streamID=\(streamID), reason=\(reason)")
        resetDesktopResizeTransactionState()

        let sharedDisplayID = await SharedVirtualDisplayManager.shared.getDisplayID()

        if let context = desktopStreamContext { await context.stop() }

        if desktopStreamMode == .mirrored, let sharedDisplayID {
            await disableDisplayMirroring(displayID: sharedDisplayID)
        }

        if let clientContext = desktopStreamClientContext {
            let message = DesktopStreamStoppedMessage(streamID: streamID, reason: reason)
            try? await clientContext.send(.desktopStreamStopped, content: message)
        }

        // Clean up
        desktopStreamContext = nil
        desktopStreamID = nil
        desktopStreamClientContext = nil
        desktopDisplayBounds = nil
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopRequestedScaleFactor = nil
        sharedVirtualDisplayScaleFactor = 2.0
        desktopStreamMode = .mirrored
        streamsByID.removeValue(forKey: streamID)
        unregisterTypingBurstRoute(streamID: streamID)
        unregisterStallWindowPointerRoute(streamID: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupRegistrationLogged.remove(streamID)
        transportSendErrorReported.remove(streamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            Task { try? await videoStream.close() }
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
        inputStreamCacheActor.remove(streamID)
        await deactivateAudioSourceIfNeeded(streamID: streamID)

        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)

        if activeStreams.isEmpty { await PowerAssertionManager.shared.disable() }

        await syncAppListRequestDeferralForInteractiveWorkload()
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()

        syncSharedClipboardState(reason: "desktop_stream_stopped")
        await updateLightsOutState()

        MirageLogger.host("Desktop stream stopped")
    }

    func resolvedDesktopCapturePressureProfile() -> WindowCaptureEngine.CapturePressureProfile {
        #if DEBUG
        let environmentValue = ProcessInfo.processInfo.environment["MIRAGE_CAPTURE_PRESSURE_PROFILE"]
        if let parsed = WindowCaptureEngine.CapturePressureProfile.parse(environmentValue) {
            return parsed
        }
        #endif
        return .baseline
    }

    /// Stop all active streams for desktop mode (mutual exclusivity)
    func stopAllStreamsForDesktopMode() async {
        MirageLogger.host("Stopping all streams for desktop mode")

        let sessions = await appStreamManager.getAllSessions()
        let windowStreams = activeStreams

        for session in windowStreams {
            MirageLogger.host("Stopping window stream: \(session.id)")
            await stopStream(session, minimizeWindow: false, updateAppSession: false)
        }

        for session in sessions {
            MirageLogger.host("Ending app session: \(session.bundleIdentifier)")
            await appStreamManager.endSession(bundleIdentifier: session.bundleIdentifier)
        }

        await restoreStageManagerAfterAppStreamingIfNeeded()
    }

    /// Find SCDisplay with retry - faster than fixed sleep
    func findSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        _ = delayMs
        let resolvedAttempts = max(maxAttempts, 12)
        do {
            let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay(maxAttempts: resolvedAttempts)
            MirageLogger.host("Found SCDisplay using shared startup policy (attempt budget \(resolvedAttempts))")
            return scDisplay
        } catch {
            MirageLogger.host("Failed to find SCDisplay using shared startup policy after \(resolvedAttempts) attempts")
            throw error
        }
    }

    /// Find main SCDisplay with retry - for desktop streaming capture
    func findMainSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        for attempt in 1 ... maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findMainSCDisplay()
                MirageLogger.host("Found main SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts { try await Task.sleep(for: .milliseconds(Int64(delayMs))) } else {
                    MirageLogger.host("Failed to find main SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageError.protocolError("Failed to find main SCDisplay")
    }

    func resolvePrimaryPhysicalDisplayID() -> CGDirectDisplayID? {
        let mainDisplayID = CGMainDisplayID()
        if !CGVirtualDisplayBridge.isVirtualDisplay(mainDisplayID) { return mainDisplayID }

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        return displays.first { !CGVirtualDisplayBridge.isVirtualDisplay($0) }
    }

    func resolveDesktopDisplaysToMirror(excluding targetDisplayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        CGVirtualDisplayBridge.getDisplaysToMirror(excludingDisplayID: targetDisplayID)
    }

    func captureDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID])
    -> [CGDirectDisplayID: CGDirectDisplayID] {
        var snapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for displayID in displayIDs {
            snapshot[displayID] = CGDisplayMirrorsDisplay(displayID)
        }
        return snapshot
    }

    func isDisplayMirroringRestored(targetDisplayID: CGDirectDisplayID) -> Bool {
        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return true }
        let mirroredCount = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }.count
        return mirroredCount == displaysToMirror.count
    }

    func restoreDisplayMirroringAfterResize(
        targetDisplayID: CGDirectDisplayID,
        maxAttempts: Int = 3
    )
    async -> Bool {
        var retryDelayMs = 500
        for attempt in 1 ... maxAttempts {
            await setupDisplayMirroring(targetDisplayID: targetDisplayID)

            // Allow CGDisplayMirror reconfiguration to settle before verifying.
            try? await Task.sleep(for: .milliseconds(retryDelayMs))

            if isDisplayMirroringRestored(targetDisplayID: targetDisplayID) {
                if attempt > 1 {
                    MirageLogger
                        .host(
                            "Desktop mirroring restore succeeded on attempt \(attempt)/\(maxAttempts)"
                        )
                }
                return true
            }

            let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)
            let mirroredCount = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }.count

            if attempt < maxAttempts {
                MirageLogger
                    .host(
                        "Desktop mirroring restore verification pending (attempt \(attempt)/\(maxAttempts), mirrored=\(mirroredCount)/\(displaysToMirror.count), target=\(targetDisplayID))"
                    )
                retryDelayMs = min(2000, Int(Double(retryDelayMs) * 1.8))
            } else {
                MirageLogger
                    .error(
                        .host,
                        "Desktop mirroring restore verification failed (attempt \(attempt)/\(maxAttempts), mirrored=\(mirroredCount)/\(displaysToMirror.count), target=\(targetDisplayID))"
                    )
            }
        }

        MirageLogger.error(.host, "Desktop mirroring restore failed after \(maxAttempts) attempts")
        return false
    }

    /// Ensure physical displays are not mirroring virtual displays during app/window streaming.
    func unmirrorPhysicalDisplaysForWindowStreamingIfNeeded() async {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)

        let physicalDisplaysMirroringVirtual = displays.compactMap { displayID -> CGDirectDisplayID? in
            guard !CGVirtualDisplayBridge.isVirtualDisplay(displayID) else { return nil }
            let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
            guard mirroredDisplayID != kCGNullDirectDisplay,
                  CGVirtualDisplayBridge.isVirtualDisplay(mirroredDisplayID) else {
                return nil
            }
            return displayID
        }

        guard !physicalDisplaysMirroringVirtual.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to unmirror physical displays")
            return
        }

        var unmirroredCount = 0
        for displayID in physicalDisplaysMirroringVirtual {
            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            if result == .success {
                unmirroredCount += 1
            } else {
                MirageLogger.error(.host, "Failed to unmirror physical display \(displayID): \(result)")
            }
        }

        guard unmirroredCount > 0 else {
            CGCancelDisplayConfiguration(config)
            return
        }

        let completion = CGCompleteDisplayConfiguration(config, .forSession)
        if completion == .success {
            MirageLogger.host("Unmirrored \(unmirroredCount) physical displays from virtual displays")
        } else {
            MirageLogger.error(.host, "Failed to complete physical display unmirror: \(completion)")
        }
    }

    /// Set up display mirroring so every non-Mirage display mirrors the shared virtual display.
    /// This keeps the virtual display as the resolution source for streaming.
    func setupDisplayMirroring(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return
        }

        let mirroredDisplayIDs = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        if mirroredDisplayIDs.count == displaysToMirror.count {
            if desktopMirroringSnapshot.isEmpty {
                desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
                MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
            }
            mirroredDesktopDisplayIDs = Set(displaysToMirror)
            MirageLogger.host("Display mirroring already enabled for \(displaysToMirror.count) displays")
            return
        }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        MirageLogger.host("Setting up mirroring for \(displaysToMirror.count) displays")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration for mirroring")
            return
        }

        var successfullyMirrored: Set<CGDirectDisplayID> = []

        for displayID in displaysToMirror {
            // Skip if already mirroring the target
            if CGDisplayMirrorsDisplay(displayID) == targetDisplayID {
                successfullyMirrored.insert(displayID)
                continue
            }

            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetDisplayID)
            if result == .success {
                successfullyMirrored.insert(displayID)
                MirageLogger.host("Configured display \(displayID) to mirror virtual display")
            } else {
                MirageLogger.error(.host, "Failed to configure display \(displayID) for mirroring: \(result)")
            }
        }

        guard !successfullyMirrored.isEmpty else {
            MirageLogger.error(.host, "No displays configured for mirroring")
            CGCancelDisplayConfiguration(config)
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
        if completeResult != .success {
            MirageLogger.error(.host, "Failed to complete mirroring configuration: \(completeResult)")
            return
        }

        mirroredDesktopDisplayIDs = successfullyMirrored
        MirageLogger
            .host(
                "Display mirroring enabled for \(successfullyMirrored.count) displays → virtual display \(targetDisplayID)"
            )
    }

    /// Temporarily suspend desktop mirroring before a virtual-display resize.
    /// This keeps resize transactions deterministic and avoids resize+mirror contention.
    func suspendDisplayMirroringForResize(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        let mirroredToTarget = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        guard !mirroredToTarget.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to suspend mirroring")
            return
        }

        var suspendedCount = 0
        for displayID in mirroredToTarget {
            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            if result == .success {
                suspendedCount += 1
            } else {
                MirageLogger.error(.host, "Failed to suspend mirroring for display \(displayID): \(result)")
            }
        }

        guard suspendedCount > 0 else {
            CGCancelDisplayConfiguration(config)
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
        if completeResult != .success {
            MirageLogger.error(.host, "Failed to complete mirroring suspend: \(completeResult)")
            return
        }

        mirroredDesktopDisplayIDs.removeAll()
        MirageLogger.host("Temporarily suspended mirroring for \(suspendedCount) displays before resize")
    }

    /// Restore display mirroring to the pre-stream configuration.
    func disableDisplayMirroring(displayID: CGDirectDisplayID) async {
        guard !desktopMirroringSnapshot.isEmpty else {
            MirageLogger.host("No display mirroring snapshot to restore")
            mirroredDesktopDisplayIDs.removeAll()
            return
        }

        MirageLogger
            .host("Restoring \(desktopMirroringSnapshot.count) displays from mirroring (virtual display \(displayID))")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.error(.host, "Failed to begin display configuration to disable mirroring")
            return
        }

        var successfullyRestored = 0

        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineIDs, &onlineCount)
        let onlineDisplays = Set(onlineIDs.prefix(Int(onlineCount)))
        for (displayID, mirroredDisplayID) in desktopMirroringSnapshot {
            guard onlineDisplays.contains(displayID) else {
                MirageLogger.host("Skipping mirroring restore for offline display \(displayID)")
                continue
            }
            let targetMirrorID = mirroredDisplayID == 0 ? kCGNullDirectDisplay : mirroredDisplayID
            guard CGDisplayMirrorsDisplay(displayID) != targetMirrorID else { continue }

            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetMirrorID)
            if result == .success { successfullyRestored += 1 } else {
                MirageLogger.host("Failed to restore mirroring for display \(displayID): \(result)")
            }
        }

        if successfullyRestored > 0 {
            let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
            if completeResult != .success { MirageLogger.error(.host, "Failed to complete disable mirroring: \(completeResult)") } else {
                MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
            }
        } else {
            CGCancelDisplayConfiguration(config)
        }

        mirroredDesktopDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
    }
}

#endif
