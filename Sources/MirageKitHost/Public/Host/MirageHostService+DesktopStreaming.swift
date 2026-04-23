//
//  MirageHostService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Desktop Streaming

enum DesktopMirroringRestoreContinuationDecision: Equatable {
    case continueRestore
    case abortStreamInactive
    case abortModeChanged
}

func desktopMirroringRestoreContinuationDecision(
    requestedStreamID: StreamID,
    activeDesktopStreamID: StreamID?,
    hasDesktopContext: Bool,
    desktopStreamMode: MirageDesktopStreamMode
)
-> DesktopMirroringRestoreContinuationDecision {
    guard requestedStreamID == activeDesktopStreamID, hasDesktopContext else {
        return .abortStreamInactive
    }
    guard desktopStreamMode == .unified else {
        return .abortModeChanged
    }
    return .continueRestore
}

func capturedDisplaySpaceSnapshot(
    displayIDs: [CGDirectDisplayID],
    currentSpaceProvider: (CGDirectDisplayID) -> CGSSpaceID
)
-> [CGDirectDisplayID: CGSSpaceID] {
    var snapshot: [CGDirectDisplayID: CGSSpaceID] = [:]
    for displayID in displayIDs {
        let spaceID = currentSpaceProvider(displayID)
        guard spaceID != 0 else { continue }
        snapshot[displayID] = spaceID
    }
    return snapshot
}

func pendingDisplaySpaceRestores(
    snapshot: [CGDirectDisplayID: CGSSpaceID],
    currentSpaceProvider: (CGDirectDisplayID) -> CGSSpaceID
)
-> [CGDirectDisplayID: CGSSpaceID] {
    snapshot.filter { displayID, expectedSpaceID in
        let currentSpaceID = currentSpaceProvider(displayID)
        guard currentSpaceID != 0 else { return false }
        return currentSpaceID != expectedSpaceID
    }
}

private let desktopStartupCaptureReadinessWindow: Duration = .milliseconds(750)

extension MirageHostService {

    /// Start streaming the desktop (unified or secondary display mode)
    /// This stops any active app/window streams for mutual exclusivity
    func startDesktopStream(
        to clientContext: ClientContext,
        displayResolution: CGSize,
        clientScaleFactor: CGFloat? = nil,
        mode: MirageDesktopStreamMode,
        cursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor,
        keyFrameInterval: Int?,
        colorDepth: MirageStreamColorDepth?,
        captureQueueDepth: Int?,
        enteredBitrate: Int?,
        bitrate: Int?,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        performanceMode: MirageStreamPerformanceMode = .standard,
        allowRuntimeQualityAdjustment: Bool?,
        lowLatencyHighResolutionCompressionBoost: Bool,
        disableResolutionCap: Bool,
        streamScale: CGFloat?,
        audioConfiguration: MirageAudioConfiguration,
        targetFrameRate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        mediaMaxPacketSize: Int = mirageDefaultMaxPacketSize,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil
    )
    async throws {
        var virtualDisplaySetupGuardToken: UUID?
        defer {
            if let token = virtualDisplaySetupGuardToken {
                Task { @MainActor [weak self] in
                    await self?.cancelVirtualDisplaySetupGuard(
                        token,
                        reason: "desktop_stream_start_aborted"
                    )
                }
            }
        }

        guard findClientContext(sessionID: clientContext.sessionID)?.client.id == clientContext.client.id else {
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }

        if let currentOwnerClientID = desktopStreamClientContext?.client.id,
           desktopStreamContext != nil,
           (disconnectingClientIDs.contains(currentOwnerClientID) || clientsByID[currentOwnerClientID] == nil) {
            MirageLogger.host(
                "Cleaning up desktop stream owned by a disconnected client before accepting a new desktop stream request"
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
        }

        if desktopStreamContext != nil, desktopStreamID == nil {
            MirageLogger.host("Cleaning up partial desktop startup state before accepting a new desktop stream request")
            await cleanupFailedDesktopStreamStartup(mode: desktopStreamMode)
        }

        // Check if desktop stream is already active
        guard desktopStreamContext == nil else {
            throw MirageError.protocolError("Desktop stream already active")
        }
        guard mediaSecurityByClientID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for desktop stream client")
        }

        let desktopStartTime = CFAbsoluteTimeGetCurrent()
        func logDesktopStartStep(_ step: String) {
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStartTime) * 1000)
            MirageLogger.host("Desktop start: \(step) (+\(deltaMs)ms)")
        }

        let resolvedAudioConfiguration = audioConfiguration.resolvedForDesktopStreamMode(mode)
        if resolvedAudioConfiguration != audioConfiguration {
            MirageLogger.host("Desktop stream audio disabled for secondary display mode")
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
        var virtualDisplayStartupSession = DesktopVirtualDisplayStartupSession(plan: virtualDisplayStartupPlan)
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
        let desktopSessionID = UUID()
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation
        self.desktopSessionID = desktopSessionID
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

        if clampedStreamScale < 1.0 {
            MirageLogger.host(
                "Desktop scale \(clampedStreamScale) → capture/encoder downscale; virtual display stays at " +
                    "\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px"
            )
        }
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = if performanceMode == .game {
            .tuned
        } else {
            resolvedDesktopCapturePressureProfile()
        }
        MirageLogger.host(
            "Desktop capture pressure profile: \(capturePressureProfile.rawValue)"
        )

        virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
            reason: "desktop_stream_start"
        )

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
        let acquisitionDeadline = ContinuousClock.now + .seconds(75)

        var attemptIndex = 0
        acquisitionLoop: while attemptIndex < virtualDisplayStartupAttempts.count {
            let attempt = virtualDisplayStartupAttempts[attemptIndex]
            virtualDisplayStartupSession.begin(attempt)
            if ContinuousClock.now >= acquisitionDeadline {
                MirageLogger.error(.host, "Desktop virtual display acquisition deadline exceeded (75s)")
                break acquisitionLoop
            }

            // Abort early if the client disconnected during acquisition to avoid
            // creating virtual displays that will be immediately destroyed.
            if streamSetupCancelled {
                MirageLogger.host("Desktop stream setup cancelled by client during acquisition loop")
                await cleanupFailedDesktopStreamStartup(mode: mode)
                throw MirageError.protocolError("Desktop stream setup cancelled by client")
            }
            if disconnectingClientIDs.contains(clientContext.client.id)
                || clientsByID[clientContext.client.id] == nil {
                MirageLogger.host("Desktop stream client disconnected during acquisition loop; aborting")
                await cleanupFailedDesktopStreamStartup(mode: mode)
                throw MirageError.protocolError("Desktop stream client disconnected during startup")
            }

            let attemptConfig = config.withInternalOverrides(colorSpace: attempt.colorSpace)
            let attemptResolution = attempt.backingScale.pixelResolution

            if attempt.isCachedTarget {
                MirageLogger.host(
                    "Retrying desktop virtual display acquisition with cached startup target: " +
                        "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                        "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName)"
                )
            } else if attempt.fallbackKind == .descriptorFallback {
                MirageLogger.host(
                    "Retrying desktop virtual display acquisition with descriptor fallback: " +
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
                    colorSpace: attempt.colorSpace,
                    creationPolicy: .singleAttempt(hiDPI: attempt.backingScale.scaleFactor > 1.5)
                )
                config = attemptConfig
                logDesktopStartStep("virtual display acquired (\(context.displayID), \(attempt.label))")
                virtualDisplayStartupSession.awaitingCaptureDisplay(displayID: context.displayID)

                let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, delayMs: 40)
                logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
                virtualDisplayStartupSession.ready(displayID: context.displayID)
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

                if mode == .unified {
                    let mirroringConfigured = await setupDisplayMirroring(
                        targetDisplayID: context.displayID,
                        expectedPixelResolution: context.resolution
                    )
                    if mirroringConfigured {
                        logDesktopStartStep("display mirroring configured")
                    } else {
                        logDesktopStartStep("display mirroring unavailable; continuing with virtual display capture")
                    }
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
                virtualDisplayStartupSession.persistIfPreferred(
                    from: context,
                    attemptedRefreshRate: attempt.refreshRate
                )
                break acquisitionLoop
            } catch {
                let failureClass = virtualDisplayStartupSession.recordFailure(error)
                await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
                desktopVirtualDisplayID = nil
                sharedVirtualDisplayGeneration = 0
                sharedVirtualDisplayScaleFactor = 1.0
                desktopDisplayBounds = nil
                desktopUsesHostResolution = false
                lastVirtualDisplayError = error

                if attempt.isCachedTarget {
                    clearDesktopVirtualDisplayStartupTarget(for: virtualDisplayStartupPlan.request)
                    MirageLogger.host(
                        "Cached desktop virtual display startup target failed; evicting cached target for current mode"
                    )
                }

                if let nextAttemptIndex = virtualDisplayStartupSession.nextRetryIndex(
                    after: failureClass,
                    attempts: virtualDisplayStartupAttempts,
                    currentIndex: attemptIndex
                ) {
                    if nextAttemptIndex != attemptIndex + 1 {
                        let skippedAttempts = virtualDisplayStartupAttempts[(attemptIndex + 1) ..< nextAttemptIndex]
                            .map(\.label)
                            .joined(separator: ", ")
                        MirageLogger.host(
                            "Desktop virtual display acquisition skipped ineligible retry rung(s) after \(attempt.label): \(skippedAttempts)"
                        )
                    }
                    MirageLogger.host(
                        "Desktop virtual display acquisition failed for \(attempt.label); retrying: \(error)"
                    )
                    attemptIndex = nextAttemptIndex
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

            attemptIndex += 1
        }

        if acquiredCaptureContext == nil {
            if let lastVirtualDisplayError {
                MirageLogger.host(
                    "Desktop virtual display acquisition failed; falling back to main display capture: " +
                        "\(lastVirtualDisplayError)"
                )
            } else {
                MirageLogger.host("Desktop virtual display acquisition produced no capture context; falling back to main display")
            }

            let fallback = try await mainDisplayDesktopCaptureFallback(reason: "virtual_display_startup_failed")
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
            desktopVirtualDisplayID = nil
            desktopPrimaryPhysicalDisplayID = fallback.displayID
            desktopPrimaryPhysicalBounds = fallback.bounds
            desktopDisplayBounds = fallback.bounds
            desktopMirroredVirtualResolution = fallback.resolution
            sharedVirtualDisplayGeneration = 0
            sharedVirtualDisplayScaleFactor = fallback.scaleFactor
            desktopUsesHostResolution = true
            acquiredCaptureContext = (
                display: fallback.display,
                resolution: fallback.resolution,
                p3CoverageStatus: nil,
                colorSpace: nil
            )
            logDesktopStartStep("main display fallback acquired (\(fallback.displayID))")
        }

        guard let acquiredCaptureContext else {
            throw MirageError.protocolError("Desktop stream display acquisition completed without a capture context")
        }
        let captureDisplay = acquiredCaptureContext.display
        let captureResolution = acquiredCaptureContext.resolution
        let captureDisplayP3CoverageStatus = acquiredCaptureContext.p3CoverageStatus
        let captureDisplayColorSpace = acquiredCaptureContext.colorSpace

        if streamSetupCancelled {
            MirageLogger.host("Desktop stream setup cancelled by client after acquisition")
            await cleanupFailedDesktopStreamStartup(mode: mode)
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }
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

        let computedStreamScale = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: captureResolution,
            requestedStreamScale: streamScale ?? 1.0,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        ).resolvedStreamScale

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
            requestedAudioChannelCount: resolvedAudioConfiguration.channelLayout.channelCount,
            maxPacketSize: mediaMaxPacketSize,
            mediaSecurityContext: nil,
            additionalFrameFlags: [.desktopStream],
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCap,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            enteredBitrate: enteredBitrate,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            captureShowsCursor: cursorPresentation.capturesHostCursor
        )
        await streamContext.setStartupBaseTime(desktopStartTime, label: "desktop stream \(streamID)")
        if let captureDisplayP3CoverageStatus {
            await streamContext.setDisplayP3CoverageStatusOverride(captureDisplayP3CoverageStatus)
        }
        await streamContext.logBitrateContract(event: "start")
        logDesktopStartStep("stream context created (\(streamID))")
        MirageLogger.host("Desktop stream performance mode: \(performanceMode.displayName)")
        if performanceMode != .game, allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for desktop stream \(streamID)")
        }
        if performanceMode != .game, !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for desktop stream \(streamID)")
        }
        let metricsClientID = clientContext.client.id
        let metricsSessionID = clientContext.sessionID
        await streamContext.setMetricsUpdateHandler { [weak self] metrics in
            self?.dispatchControlWork(clientID: metricsClientID) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(sessionID: metricsSessionID) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Desktop stream metrics",
                        sessionID: metricsSessionID
                    )
                }
            }
        }

        if streamSetupCancelled {
            MirageLogger.host("Desktop stream setup cancelled by client before activation")
            await cleanupFailedDesktopStreamStartup(mode: mode)
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
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
        var effectiveAudioConfiguration = resolvedAudioConfiguration
        if effectiveAudioConfiguration.enabled {
            do {
                try await activateAudioForClient(
                    clientID: clientContext.client.id,
                    expectedSessionID: clientContext.sessionID,
                    sourceStreamID: streamID,
                    configuration: effectiveAudioConfiguration
                )
            } catch {
                MirageLogger.host(
                    "Desktop audio activation failed; retrying desktop stream without audio: " +
                        "\(error.localizedDescription)"
                )
                effectiveAudioConfiguration.enabled = false
                audioConfigurationByClientID[clientContext.client.id] = effectiveAudioConfiguration
                await stopAudioPipeline(for: clientContext.client.id, reason: .error)
                await closeAudioTransportIfNeeded(for: clientContext.client.id)
                await streamContext.setCapturedAudioHandler(nil)
            }
        }
        guard !disconnectingClientIDs.contains(clientContext.client.id),
              let activeClientContext = findClientContext(sessionID: clientContext.sessionID) else {
            MirageLogger.host("Desktop stream client disconnected after audio activation; aborting startup")
            await cleanupFailedDesktopStreamStartup(mode: mode)
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }
        desktopStreamClientContext = activeClientContext

        syncSharedClipboardState(reason: "desktop_stream_started")
        await updateLightsOutState()
        let excludedWindows = await resolveLightsOutExcludedWindows()

        // Register for input handling.
        // For mirrored virtual displays, use the aspect-fit content bounds within the
        // physical display so input matches the mirrored content area.
        let mainDisplayBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputGeometry = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: mainDisplayBounds,
            virtualResolution: captureResolution
        )
        let desktopWindow = MirageWindow(
            id: 0,
            title: "Desktop",
            application: nil,
            frame: inputGeometry.inputBounds,
            isOnScreen: true,
            windowLayer: 0
        )
        inputStreamCacheActor.set(streamID, window: desktopWindow, client: activeClientContext.client)
        if let token = virtualDisplaySetupGuardToken {
            await completeVirtualDisplaySetupGuard(
                token,
                reason: "desktop_stream_start"
            )
            virtualDisplaySetupGuardToken = nil
        }

        // Enable power assertion
        await PowerAssertionManager.shared.enable()

        // Open Loom video stream for desktop streaming
        let activeVideoStream: LoomMultiplexedStream
        do {
            let openedVideoStream = try await activeClientContext.controlChannel.session.openStream(
                label: "video/\(streamID)"
            )
            activeVideoStream = openedVideoStream
            loomVideoStreamsByStreamID[streamID] = openedVideoStream
            transportRegistry.registerVideoStream(openedVideoStream, streamID: streamID)
            MirageLogger.host("Opened Loom video stream for desktop stream \(streamID)")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to open Loom video stream for desktop stream \(streamID): "
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            throw error
        }

        // Start streaming the display with direct Loom send ownership in StreamPacketSender.
        let firstSuccessfulVideoPacketSent = Locked(false)
        do {
            let startDesktopDisplay: () async throws -> Void = {
                try await streamContext.startDesktopDisplay(
                    displayWrapper: captureDisplay,
                    resolution: captureResolution,
                    excludedWindows: excludedWindows,
                    sendPacket: { packetData, onComplete in
                        activeVideoStream.sendUnreliableQueued(packetData) { error in
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
                            }
                            onComplete(error)
                        }
                    },
                    onSendError: { [weak self] error in
                        guard let self else { return }
                        dispatchMainWork {
                            await self.handleVideoSendError(streamID: streamID, error: error)
                        }
                    }
                )
            }

            do {
                try await startDesktopDisplay()
            } catch {
                guard effectiveAudioConfiguration.enabled else { throw error }
                MirageLogger.host(
                    "Desktop display capture start failed with audio enabled; retrying without audio: " +
                        "\(error.localizedDescription)"
                )
                effectiveAudioConfiguration.enabled = false
                audioConfigurationByClientID[clientContext.client.id] = effectiveAudioConfiguration
                await stopAudioPipeline(for: clientContext.client.id, reason: .error)
                await closeAudioTransportIfNeeded(for: clientContext.client.id)
                await streamContext.setCapturedAudioHandler(nil)
                try await startDesktopDisplay()
            }

        if mode == .unified {
            var recoveryAttempted = false
            while true {
                var readiness = await streamContext.waitForDisplayStartupReadiness(
                    timeout: desktopStartupCaptureReadinessWindow
                )
                let capturedStartupSeedFrame: Bool
                if readiness == .noScreenSamples {
                    capturedStartupSeedFrame = await streamContext.seedDisplayStartupFrameIfNeeded()
                    if !capturedStartupSeedFrame {
                        readiness = await streamContext.waitForDisplayStartupReadiness(
                            timeout: .milliseconds(250)
                        )
                    }
                } else {
                    capturedStartupSeedFrame = false
                }
                let hasCachedStartupFrame = await streamContext.hasCachedStartupFrame()
                let hasObservedStartupSample = await streamContext.hasObservedDisplayStartupSample()
                switch desktopStartupCaptureRecoveryDecision(
                    readiness: readiness,
                    recoveryAttempted: recoveryAttempted,
                    hasCachedStartupFrame: hasCachedStartupFrame,
                    hasObservedStartupSample: hasObservedStartupSample
                ) {
                case .proceed:
                    if readiness == .noScreenSamples {
                        MirageLogger.host(
                            "Desktop start: proceeding without a live startup frame " +
                                "(cachedSeed=\(capturedStartupSeedFrame || hasCachedStartupFrame), " +
                                "observedSample=\(hasObservedStartupSample))"
                        )
                    } else {
                        MirageLogger.host(
                            "Desktop start: capture readiness satisfied (\(readiness.rawValue))"
                        )
                    }
                    break
                case .restartCapture:
                    recoveryAttempted = true
                    MirageLogger.host(
                        "Desktop start: capture readiness \(readiness.rawValue); restarting display capture once"
                    )
                    await streamContext.restartDisplayCaptureForStartupRecovery(
                        reason: "startup_capture_readiness_\(readiness.rawValue)"
                    )
                    continue
                case .fail:
                    throw MirageError.protocolError(
                        "Unified desktop startup failed waiting for first display sample (\(readiness.rawValue))"
                    )
                }
                break
            }
        }
        logDesktopStartStep("capture and encoder started")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Desktop display capture start failed; cleaning up stream state: "
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            throw error
        }

        // Send stream-started to client BEFORE enabling encoding so the client's
        // controller/reassembler is ready when video packets arrive.
        // (Window streams already follow this order — see MirageHostService+Streams.swift.)
        let dimensionToken = await streamContext.getDimensionToken()
        let startedDisplayResolution = await currentDesktopStartedResolution(fallback: captureResolution)
        let targetFrameRate = await streamContext.getTargetFrameRate()
        let codec = await streamContext.getCodec()
        let acceptedMediaMaxPacketSize = await streamContext.getMediaMaxPacketSize()
        let startupAttemptID = UUID()
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(startedDisplayResolution.width),
            height: Int(startedDisplayResolution.height),
            frameRate: targetFrameRate,
            codec: codec,
            startupAttemptID: startupAttemptID,
            displayCount: 1,
            dimensionToken: dimensionToken,
            acceptedMediaMaxPacketSize: acceptedMediaMaxPacketSize,
            transitionPhase: .startup
        )
        do {
            registerPendingStartupAttempt(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                sessionID: activeClientContext.sessionID,
                clientID: activeClientContext.client.id,
                kind: .desktop
            )
            try await activeClientContext.send(.desktopStreamStarted, content: message)
            MirageLogger.signpostEvent(.host, "Startup.StreamStartedSent", "stream=\(streamID) kind=desktop")
            logDesktopStartStep("desktopStreamStarted sent")
        } catch {
            cancelPendingStartupAttempt(streamID: streamID)
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            MirageLogger.error(.host, error: error, message: "Failed to send desktopStreamStarted: ")
            logDesktopStartStep("desktopStreamStarted send failed")
            throw MirageError.protocolError("Desktop stream startup acknowledgement could not be delivered to the client")
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
        if let context = desktopStreamContext {
            await context.stop()
        }
        desktopStreamContext = nil
        desktopStreamClientContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopRequestedScaleFactor = nil
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
        if let vdID = desktopVirtualDisplayID {
            if mode == .unified {
                await disableDisplayMirroring(displayID: vdID)
            }
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        }
        desktopVirtualDisplayID = nil
        desktopDisplayBounds = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopMirroredVirtualResolution = nil
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = 1.0
        desktopUsesHostResolution = false
        mirroredDesktopDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
        desktopDisplaySpaceSnapshot.removeAll()
    }

    /// Stop the desktop stream
    func stopDesktopStream(
        reason: DesktopStreamStopReason = .clientRequested,
        triggeredByExplicitStreamStop: Bool = true
    ) async {
        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        guard let streamID = desktopStreamID else {
            if desktopStreamContext != nil || desktopVirtualDisplayID != nil || desktopStreamClientContext != nil {
                MirageLogger.host("Stopping partial desktop stream startup state without an established stream ID")
                await cleanupFailedDesktopStreamStartup(mode: desktopStreamMode)
            }
            await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
            return
        }

        cancelPendingStartupAttempt(streamID: streamID)
        let stoppedDesktopSessionID = desktopSessionID
        let stoppedClientContext = desktopStreamClientContext
        MirageLogger.host(
            "Stopping desktop stream: streamID=\(streamID), session=\(stoppedDesktopSessionID?.uuidString ?? "nil"), reason=\(reason)"
        )
        beginDesktopSharedDisplayTransition()
        defer { endDesktopSharedDisplayTransition() }
        resetDesktopResizeTransactionState()

        let sharedDisplayID = await SharedVirtualDisplayManager.shared.getDisplayID()

        if let context = desktopStreamContext { await context.stop() }

        if desktopStreamMode == .unified, let sharedDisplayID {
            await disableDisplayMirroring(displayID: sharedDisplayID)
        }

        if let clientContext = stoppedClientContext,
           let stoppedDesktopSessionID {
            let message = DesktopStreamStoppedMessage(
                streamID: streamID,
                desktopSessionID: stoppedDesktopSessionID,
                reason: reason
            )
            try? await clientContext.send(.desktopStreamStopped, content: message)
        }

        // Clean up
        desktopStreamContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopStreamClientContext = nil
        desktopDisplayBounds = nil
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopMirroredVirtualResolution = nil
        desktopRequestedScaleFactor = nil
        desktopUsesHostResolution = false
        sharedVirtualDisplayScaleFactor = 2.0
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
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
        lockHostIfStreamingStopped(triggeredByExplicitStreamStop: triggeredByExplicitStreamStop)

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

    func mainDisplayDesktopCaptureFallback(
        reason: String,
        maxAttempts: Int = 8,
        delayMs: UInt64 = 80
    )
    async throws -> (
        display: SCDisplayWrapper,
        resolution: CGSize,
        displayID: CGDirectDisplayID,
        bounds: CGRect,
        scaleFactor: CGFloat
    ) {
        let display = try await findMainSCDisplayWithRetry(maxAttempts: maxAttempts, delayMs: delayMs)
        let displayID = display.display.displayID
        let resolution = CGSize(
            width: CGFloat(display.display.width),
            height: CGFloat(display.display.height)
        )
        let bounds = CGDisplayBounds(displayID)
        guard resolution.width > 0, resolution.height > 0 else {
            throw MirageError.protocolError("Main display fallback has invalid capture resolution")
        }

        let scaleFactor: CGFloat = if bounds.width > 0, bounds.height > 0 {
            max(1.0, max(resolution.width / bounds.width, resolution.height / bounds.height))
        } else {
            1.0
        }
        MirageLogger.host(
            "Desktop capture fallback using main display \(displayID): " +
                "\(Int(resolution.width))x\(Int(resolution.height)) px, reason=\(reason)"
        )
        return (display, resolution, displayID, bounds, scaleFactor)
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

    func captureDisplaySpaceSnapshot(
        for displayIDs: [CGDirectDisplayID],
        overwriteExisting: Bool
    ) {
        let snapshot = capturedDisplaySpaceSnapshot(
            displayIDs: displayIDs,
            currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
        )
        guard !snapshot.isEmpty else { return }

        if overwriteExisting || desktopDisplaySpaceSnapshot.isEmpty {
            desktopDisplaySpaceSnapshot = snapshot
        } else {
            for displayID in displayIDs {
                guard desktopDisplaySpaceSnapshot[displayID] == nil,
                      let spaceID = snapshot[displayID] else { continue }
                desktopDisplaySpaceSnapshot[displayID] = spaceID
            }
        }

        MirageLogger.host("Captured display space snapshot for \(snapshot.count) displays")
    }

    func captureDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID])
    -> [CGDirectDisplayID: CGDirectDisplayID] {
        var snapshot: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for displayID in displayIDs {
            snapshot[displayID] = CGDisplayMirrorsDisplay(displayID)
        }
        return snapshot
    }

    func restoreDisplaySpaceSnapshotIfNeeded(
        reason: String,
        maxAttempts: Int = 3
    )
    async {
        guard !desktopDisplaySpaceSnapshot.isEmpty else { return }

        for attempt in 1 ... maxAttempts {
            let pending = pendingDisplaySpaceRestores(
                snapshot: desktopDisplaySpaceSnapshot,
                currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
            )
            if pending.isEmpty { return }

            for displayID in pending.keys.sorted() {
                guard let expectedSpaceID = pending[displayID] else { continue }
                if !CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: expectedSpaceID) {
                    MirageLogger.host(
                        "Failed to restore current space \(expectedSpaceID) for display \(displayID) " +
                            "(reason=\(reason), attempt=\(attempt))"
                    )
                }
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(Int64(120 * attempt)))
            }
        }

        let unresolved = pendingDisplaySpaceRestores(
            snapshot: desktopDisplaySpaceSnapshot,
            currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
        )
        if !unresolved.isEmpty {
            let unresolvedSummary = unresolved
                .keys
                .sorted()
                .compactMap { displayID in
                    guard let expectedSpaceID = unresolved[displayID] else { return nil }
                    let actualSpaceID = CGSWindowSpaceBridge.getCurrentSpaceForDisplay(displayID)
                    return "\(displayID): expected=\(expectedSpaceID), actual=\(actualSpaceID)"
                }
                .joined(separator: "; ")
            MirageLogger.error(
                .host,
                "Display current Space restore remained incomplete after \(maxAttempts) attempts " +
                    "(reason=\(reason)): \(unresolvedSummary)"
            )
        }
    }

    func isDisplayMirroringRestored(targetDisplayID: CGDirectDisplayID) -> Bool {
        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return true }
        let mirroredCount = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }.count
        return mirroredCount == displaysToMirror.count
    }

    func restoreDisplayMirroringAfterResize(
        streamID: StreamID,
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize,
        maxAttempts: Int = 3
    )
    async -> Bool {
        switch desktopMirroringRestoreContinuationDecision(
            requestedStreamID: streamID,
            activeDesktopStreamID: desktopStreamID,
            hasDesktopContext: desktopStreamContext != nil,
            desktopStreamMode: desktopStreamMode
        ) {
        case .continueRestore:
            break
        case .abortStreamInactive:
            MirageLogger.host("Aborting desktop mirroring restore because the stream is no longer active")
            return false
        case .abortModeChanged:
            MirageLogger.host("Aborting desktop mirroring restore because desktop stream mode changed")
            return false
        }

        guard await setupDisplayMirroring(
            targetDisplayID: targetDisplayID,
            expectedPixelResolution: expectedPixelResolution
        ) else {
            MirageLogger.host(
                "Desktop mirroring restore could not start; continuing with virtual display capture"
            )
            return false
        }

        var retryDelayMs = 500
        for attempt in 1 ... maxAttempts {
            // Allow CGDisplayMirror reconfiguration to settle before verifying.
            try? await Task.sleep(for: .milliseconds(retryDelayMs))

            switch desktopMirroringRestoreContinuationDecision(
                requestedStreamID: streamID,
                activeDesktopStreamID: desktopStreamID,
                hasDesktopContext: desktopStreamContext != nil,
                desktopStreamMode: desktopStreamMode
            ) {
            case .continueRestore:
                break
            case .abortStreamInactive:
                MirageLogger.host("Aborting desktop mirroring restore because the stream is no longer active")
                return false
            case .abortModeChanged:
                MirageLogger.host("Aborting desktop mirroring restore because desktop stream mode changed")
                return false
            }

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
                _ = await setupDisplayMirroring(
                    targetDisplayID: targetDisplayID,
                    expectedPixelResolution: expectedPixelResolution
                )
                retryDelayMs = min(2000, Int(Double(retryDelayMs) * 1.8))
            } else {
                MirageLogger
                    .host(
                        "Desktop mirroring restore verification failed (attempt \(attempt)/\(maxAttempts), mirrored=\(mirroredCount)/\(displaysToMirror.count), target=\(targetDisplayID))"
                    )
            }
        }

        MirageLogger.host("Desktop mirroring restore failed after \(maxAttempts) attempts")
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
            MirageLogger.host("Physical display unmirror unavailable: failed to begin display configuration")
            return
        }

        var unmirroredCount = 0
        for displayID in physicalDisplaysMirroringVirtual {
            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            if result == .success {
                unmirroredCount += 1
            } else {
                MirageLogger.host("Physical display unmirror skipped display \(displayID): \(result)")
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
            MirageLogger.host("Physical display unmirror unavailable: failed to complete configuration \(completion)")
        }
    }

    /// Set up display mirroring so every non-Mirage display mirrors the shared virtual display.
    /// This keeps the virtual display as the resolution source for streaming.
    @discardableResult
    func setupDisplayMirroring(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize? = nil
    )
    async -> Bool {
        guard await waitForDisplayMirroringTargetStability(
            targetDisplayID: targetDisplayID,
            expectedPixelResolution: expectedPixelResolution
        ) else {
            MirageLogger.host(
                "Display mirroring setup deferred because virtual display \(targetDisplayID) did not stabilize"
            )
            return false
        }

        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)

        guard !displaysToMirror.isEmpty else {
            MirageLogger.host("No displays found to mirror")
            return true
        }

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: false)

        let mirroredDisplayIDs = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        if mirroredDisplayIDs.count == displaysToMirror.count {
            if desktopMirroringSnapshot.isEmpty {
                desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
                MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
            }
            mirroredDesktopDisplayIDs = Set(displaysToMirror)
            MirageLogger.host("Display mirroring already enabled for \(displaysToMirror.count) displays")
            await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup_noop")
            return true
        }

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        MirageLogger.host("Setting up mirroring for \(displaysToMirror.count) displays")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.host("Display mirroring setup unavailable: failed to begin display configuration")
            return false
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
                MirageLogger.host("Display mirroring setup skipped display \(displayID): \(result)")
            }
        }

        guard !successfullyMirrored.isEmpty else {
            MirageLogger.host("Display mirroring setup unavailable: no displays accepted mirroring configuration")
            CGCancelDisplayConfiguration(config)
            return false
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
        if completeResult != .success {
            MirageLogger.host("Display mirroring setup unavailable: failed to complete configuration \(completeResult)")
            CGCancelDisplayConfiguration(config)
            return false
        }

        mirroredDesktopDisplayIDs = successfullyMirrored
        MirageLogger
            .host(
                "Display mirroring enabled for \(successfullyMirrored.count) displays → virtual display \(targetDisplayID)"
            )
        await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup")
        return successfullyMirrored.count == displaysToMirror.count
    }

    private func waitForDisplayMirroringTargetStability(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize?,
        stableSampleCount: Int = 2,
        maxWaitMs: Int = 2500,
        pollIntervalMs: Int = 120
    )
    async -> Bool {
        let deadline = Date().addingTimeInterval(Double(maxWaitMs) / 1000.0)
        var consecutiveStableSamples = 0
        var lastDecision: DisplayMirroringTargetStabilityDecision = .waitForTargetOnline

        while true {
            let onlineDisplayIDs = currentOnlineDisplayIDsForMirroringStability()
            let observedResolution = CGVirtualDisplayBridge.currentDisplayModeSizes(targetDisplayID)?.pixel
            let decision = displayMirroringTargetStabilityDecision(
                targetDisplayID: targetDisplayID,
                onlineDisplayIDs: onlineDisplayIDs,
                observedTargetPixelResolution: observedResolution,
                expectedTargetPixelResolution: expectedPixelResolution
            )
            lastDecision = decision

            if decision == .stable {
                consecutiveStableSamples += 1
                if consecutiveStableSamples >= stableSampleCount { return true }
            } else {
                consecutiveStableSamples = 0
            }

            guard Date() < deadline else {
                MirageLogger.host(
                    "Display mirroring target stability timed out for \(targetDisplayID): " +
                        displayMirroringTargetStabilityDescription(lastDecision)
                )
                return false
            }

            try? await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
    }

    private func currentOnlineDisplayIDsForMirroringStability() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return Array(displays.prefix(Int(displayCount)))
    }

    private func displayMirroringTargetStabilityDescription(
        _ decision: DisplayMirroringTargetStabilityDecision
    )
    -> String {
        switch decision {
        case .stable:
            return "stable"
        case .waitForTargetOnline:
            return "target display not online"
        case let .waitForExpectedMode(observed, expected):
            let expectedText = "\(Int(expected.width))x\(Int(expected.height))"
            guard let observed else { return "target mode unavailable, expected \(expectedText)" }
            return "target mode \(Int(observed.width))x\(Int(observed.height)) != expected \(expectedText)"
        case let .waitForResidualMirageDisplays(displayIDs):
            return "residual Mirage displays still online: \(displayIDs)"
        }
    }

    /// Temporarily suspend desktop mirroring before a virtual-display resize.
    /// This keeps resize transactions deterministic and avoids resize+mirror contention.
    func suspendDisplayMirroringForResize(targetDisplayID: CGDirectDisplayID) async {
        let displaysToMirror = resolveDesktopDisplaysToMirror(excluding: targetDisplayID)
        guard !displaysToMirror.isEmpty else { return }

        captureDisplaySpaceSnapshot(for: displaysToMirror, overwriteExisting: true)

        if desktopMirroringSnapshot.isEmpty {
            desktopMirroringSnapshot = captureDisplayMirroringSnapshot(for: displaysToMirror)
            MirageLogger.host("Captured display mirroring snapshot for \(desktopMirroringSnapshot.count) displays")
        }

        let mirroredToTarget = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        guard !mirroredToTarget.isEmpty else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.host("Display mirroring suspend unavailable: failed to begin display configuration")
            return
        }

        var suspendedCount = 0
        for displayID in mirroredToTarget {
            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            if result == .success {
                suspendedCount += 1
            } else {
                MirageLogger.host("Display mirroring suspend skipped display \(displayID): \(result)")
            }
        }

        guard suspendedCount > 0 else {
            CGCancelDisplayConfiguration(config)
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
        if completeResult != .success {
            MirageLogger.host("Display mirroring suspend unavailable: failed to complete configuration \(completeResult)")
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
            desktopDisplaySpaceSnapshot.removeAll()
            return
        }

        captureDisplaySpaceSnapshot(
            for: desktopMirroringSnapshot.keys.sorted(),
            overwriteExisting: true
        )

        MirageLogger
            .host("Restoring \(desktopMirroringSnapshot.count) displays from mirroring (virtual display \(displayID))")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            MirageLogger.host("Display mirroring restore unavailable: failed to begin display configuration")
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
            let targetMirrorID: CGDirectDisplayID
            if mirroredDisplayID == 0 {
                targetMirrorID = kCGNullDirectDisplay
            } else if onlineDisplays.contains(mirroredDisplayID) {
                targetMirrorID = mirroredDisplayID
            } else {
                targetMirrorID = kCGNullDirectDisplay
                MirageLogger.host(
                    "Skipping restore to offline mirror target \(mirroredDisplayID); unmirroring display \(displayID) instead"
                )
            }
            guard CGDisplayMirrorsDisplay(displayID) != targetMirrorID else { continue }

            let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, targetMirrorID)
            if result == .success { successfullyRestored += 1 } else {
                MirageLogger.host("Failed to restore mirroring for display \(displayID): \(result)")
            }
        }

        if successfullyRestored > 0 {
            let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
            if completeResult != .success {
                MirageLogger.host("Display mirroring restore unavailable: failed to complete configuration \(completeResult)")
                CGCancelDisplayConfiguration(config)
            } else {
                MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
                await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable")
            }
        } else {
            CGCancelDisplayConfiguration(config)
            await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_noop")
        }

        mirroredDesktopDisplayIDs.removeAll()
        desktopMirroringSnapshot.removeAll()
        desktopDisplaySpaceSnapshot.removeAll()
    }
}

#endif
