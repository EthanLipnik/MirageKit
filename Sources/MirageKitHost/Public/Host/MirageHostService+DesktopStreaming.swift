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

func aspectFitPixelSize(contentSize: CGSize, containerSize: CGSize) -> CGSize {
    guard contentSize.width > 0, contentSize.height > 0,
          containerSize.width > 0, containerSize.height > 0 else {
        return contentSize
    }
    let contentAspect = contentSize.width / contentSize.height
    let containerAspect = containerSize.width / containerSize.height
    if containerAspect > contentAspect {
        let height = containerSize.height
        return CGSize(width: height * contentAspect, height: height)
    }
    let width = containerSize.width
    return CGSize(width: width, height: width / contentAspect)
}

private let desktopStartupCaptureReadinessWindow: Duration = .milliseconds(750)
private let desktopSyntheticStartupRecoveryAttemptInterval: Duration = .milliseconds(3_250)
private let desktopSyntheticStartupRecoveryMaxAttempts = 2
private let desktopLowestLatencyFixedQualityBitrateCapBps = 150_000_000

extension MirageHostService {

    nonisolated static func resolvedDesktopEncoderBitrate(
        requestedBitrate: Int?,
        latencyMode: MirageStreamLatencyMode,
        allowRuntimeQualityAdjustment: Bool?
    ) -> Int? {
        guard let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: requestedBitrate
        ) else {
            return nil
        }
        guard latencyMode == .lowestLatency,
              allowRuntimeQualityAdjustment == false,
              normalizedBitrate > desktopLowestLatencyFixedQualityBitrateCapBps else {
            return normalizedBitrate
        }
        return desktopLowestLatencyFixedQualityBitrateCapBps
    }

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
        codec: MirageVideoCodec? = nil,
        startupRequestID: UUID
    )
    async throws {
        var virtualDisplaySetupGuardToken: UUID?
        var clearDesktopStartupMarkerOnExit = false
        defer {
            if let token = virtualDisplaySetupGuardToken {
                Task { @MainActor [weak self] in
                    await self?.cancelVirtualDisplaySetupGuard(
                        token,
                        reason: "desktop_stream_start_aborted"
                    )
                }
            }
            let shouldClearDesktopStartupMarker = clearDesktopStartupMarkerOnExit &&
                deferredDesktopStartupDisplayCleanupTask == nil
            if shouldClearDesktopStartupMarker {
                Task {
                    await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
                }
            }
        }

        guard findClientContext(sessionID: clientContext.sessionID)?.client.id == clientContext.client.id else {
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }

        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = nil

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
        MirageLogger.host(
            "Desktop stream audio configuration: requestedEnabled=\(audioConfiguration.enabled), " +
                "effectiveEnabled=\(resolvedAudioConfiguration.enabled), " +
                "layout=\(resolvedAudioConfiguration.channelLayout.rawValue), " +
                "quality=\(resolvedAudioConfiguration.quality.rawValue), mode=\(mode.rawValue)"
        )

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
        let resolvedCodec = effectiveVideoCodec(for: codec)
        let resolvedColorDepth = effectiveColorDepth(for: colorDepth, codec: resolvedCodec)
        let virtualDisplayStartupSurface = desktopVirtualDisplayStartupSurface(
            requestedLogicalResolution: displayResolution,
            requestedScaleFactor: defaultDesktopBackingScale
        )
        if let colorDepth, let resolvedColorDepth, colorDepth != resolvedColorDepth {
            MirageLogger.host(
                "Desktop color depth request downgraded: requested=\(colorDepth.displayName), effective=\(resolvedColorDepth.displayName)"
            )
        }
        let virtualDisplayStartupPlan = desktopVirtualDisplayStartupPlan(
            logicalResolution: virtualDisplayStartupSurface.logicalResolution,
            requestedScaleFactor: virtualDisplayStartupSurface.requestedScaleFactor,
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
                logicalResolution: virtualDisplayStartupSurface.logicalResolution,
                defaultScaleFactor: virtualDisplayStartupSurface.requestedScaleFactor
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
        let streamID = nextStreamID
        nextStreamID += 1
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation
        desktopCaptureSource = .virtualDisplay
        resetDesktopClientFitFallbackState()
        self.desktopSessionID = desktopSessionID
        resetDesktopResizeTransactionState()
        await HostDesktopStreamTerminationTracker.shared.markDesktopDisplaySetupStarted(
            streamID: streamID,
            requestedPixelResolution: virtualDisplayResolution
        )
        clearDesktopStartupMarkerOnExit = true

        // Configure encoder with optional overrides
        var config = encoderConfig
        config = config.withOverrides(
            keyFrameInterval: keyFrameInterval,
            colorDepth: resolvedColorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )

        if let resolvedCodec {
            config.codec = resolvedCodec
        }

        let requestedBitrate = config.bitrate
        config.bitrate = Self.resolvedDesktopEncoderBitrate(
            requestedBitrate: requestedBitrate,
            latencyMode: latencyMode,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment
        )
        if let requestedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: requestedBitrate),
           let resolvedBitrate = config.bitrate,
           resolvedBitrate < requestedBitrate {
            let requestedMbps = (Double(requestedBitrate) / 1_000_000.0)
                .formatted(.number.precision(.fractionLength(1)))
            let resolvedMbps = (Double(resolvedBitrate) / 1_000_000.0)
                .formatted(.number.precision(.fractionLength(1)))
            MirageLogger.host(
                "Desktop stream bitrate capped for fixed lowest-latency quality: " +
                    "\(requestedMbps) Mbps -> \(resolvedMbps) Mbps"
            )
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
        let capturePressureProfile = resolvedDesktopCapturePressureProfile()
        MirageLogger.host(
            "Desktop capture pressure profile: \(capturePressureProfile.rawValue)"
        )

        var acquiredCaptureContext: (
            display: SCDisplayWrapper,
            resolution: CGSize,
            p3CoverageStatus: MirageDisplayP3CoverageStatus?,
            colorSpace: MirageColorSpace?,
            captureSource: MirageDesktopCaptureSource,
            allowsClientResize: Bool,
            presentationResolution: CGSize,
            virtualDisplaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
            usesDisplayRefreshCadence: Bool?
        )?
        var lastVirtualDisplayError: Error?
        let startupBudget = DesktopVirtualDisplayStartupBudget(maxDuration: 10.0)
        let requestedDesktopUsesHostResolution = desktopUsesHostResolution

        if requestedDesktopUsesHostResolution {
            let fallback = try await mainDisplayDesktopCaptureFallback(reason: "host_resolution_requested")
            try await ensureDesktopStreamSetupCanContinue(
                clientContext: clientContext,
                startupRequestID: startupRequestID,
                mode: mode,
                stage: "after host-resolution main display acquisition"
            )
            desktopVirtualDisplayID = nil
            desktopPrimaryPhysicalDisplayID = fallback.displayID
            desktopPrimaryPhysicalBounds = fallback.bounds
            desktopDisplayBounds = fallback.bounds
            desktopMirroredVirtualResolution = fallback.resolution
            sharedVirtualDisplayGeneration = 0
            sharedVirtualDisplayScaleFactor = fallback.scaleFactor
            desktopUsesHostResolution = true
            desktopCaptureSource = .mainDisplayFallback
            let presentationResolution = aspectFitPixelSize(
                contentSize: fallback.resolution,
                containerSize: virtualDisplayResolution
            )
            let mirroringConfigured = await setupDisplayMirroring(
                targetDisplayID: fallback.displayID,
                expectedPixelResolution: fallback.resolution,
                requiresResidualMirageDisplaysClear: false
            )
            if mirroringConfigured {
                logDesktopStartStep("host-resolution main display mirroring configured")
            } else {
                logDesktopStartStep("host-resolution main display mirroring incomplete; continuing")
            }
            try await ensureDesktopStreamSetupCanContinue(
                clientContext: clientContext,
                startupRequestID: startupRequestID,
                mode: mode,
                stage: "after host-resolution mirroring"
            )
            acquiredCaptureContext = (
                display: fallback.display,
                resolution: fallback.resolution,
                p3CoverageStatus: nil,
                colorSpace: nil,
                captureSource: .mainDisplayFallback,
                allowsClientResize: false,
                presentationResolution: presentationResolution,
                virtualDisplaySnapshot: nil,
                usesDisplayRefreshCadence: nil
            )
            logDesktopStartStep("host-resolution main display acquired (\(fallback.displayID))")
        }

        if !requestedDesktopUsesHostResolution {
            virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
                reason: "desktop_stream_start"
            )
            if mode == .unified {
                let preCreationDisplayIDs = currentOnlineDisplayIDsForMirroringStability()
                    .filter { !CGVirtualDisplayBridge.isMirageDisplay($0) }
                if !preCreationDisplayIDs.isEmpty {
                    captureDisplaySpaceSnapshot(for: preCreationDisplayIDs, overwriteExisting: false)
                    mergeDisplayMirroringSnapshot(for: preCreationDisplayIDs)
                }
            }

            // Acquire the virtual display at the requested display geometry. Encoder
            // resolution caps are applied through stream scale without changing it.
            // Pass the target frame rate to enable 120Hz when appropriate.
            var attemptIndex = 0
            acquisitionLoop: while attemptIndex < virtualDisplayStartupAttempts.count {
                let attempt = virtualDisplayStartupAttempts[attemptIndex]
                virtualDisplayStartupSession.begin(attempt)
                if startupBudget.isExpired {
                    MirageLogger.error(.host, "Desktop virtual display acquisition budget exceeded (10s)")
                    lastVirtualDisplayError = DesktopVirtualDisplayStartupBudgetExceeded()
                    break acquisitionLoop
                }

                // Abort early if the client disconnected during acquisition to avoid
                // creating virtual displays that will be immediately destroyed.
                try await ensureDesktopStreamSetupCanContinue(
                    clientContext: clientContext,
                    startupRequestID: startupRequestID,
                    mode: mode,
                    stage: "during acquisition loop"
                )

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
                        creationPolicy: .singleAttempt(hiDPI: attempt.backingScale.scaleFactor > 1.5),
                        startupBudget: startupBudget
                    )
                    config = attemptConfig
                    logDesktopStartStep("virtual display acquired (\(context.displayID), \(attempt.label))")
                    desktopVirtualDisplayID = context.displayID
                    desktopCaptureSource = .virtualDisplay
                    try await ensureDesktopStreamSetupCanContinue(
                        clientContext: clientContext,
                        startupRequestID: startupRequestID,
                        mode: mode,
                        stage: "after virtual display acquire"
                    )
                    virtualDisplayStartupSession.awaitingCaptureDisplay(displayID: context.displayID)
                    if mode == .secondary {
                        await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(targetDisplayID: context.displayID)
                        try await ensureDesktopStreamSetupCanContinue(
                            clientContext: clientContext,
                            startupRequestID: startupRequestID,
                            mode: mode,
                            stage: "after secondary display unmirror"
                        )
                    }

                    let captureDisplay = try await findSCDisplayWithRetry(
                        maxAttempts: 5,
                        startupBudget: startupBudget,
                        expectedPixelResolution: context.resolution
                    )
                    logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
                    try await ensureDesktopStreamSetupCanContinue(
                        clientContext: clientContext,
                        startupRequestID: startupRequestID,
                        mode: mode,
                        stage: "after ScreenCaptureKit display resolution"
                    )
                    virtualDisplayStartupSession.ready(displayID: context.displayID)
                    let captureResolution = context.resolution
                    let captureDisplayP3CoverageStatus = context.displayP3CoverageStatus
                    let captureDisplayColorSpace = context.colorSpace

                    desktopVirtualDisplayID = context.displayID
                    desktopCaptureSource = .virtualDisplay
                    var resolvedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds()
                    try await ensureDesktopStreamSetupCanContinue(
                        clientContext: clientContext,
                        startupRequestID: startupRequestID,
                        mode: mode,
                        stage: "after virtual display bounds lookup"
                    )
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
                        desktopPhysicalDisplayTopologySignature = currentPhysicalDisplayTopologySignature()
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
                            logDesktopStartStep("display mirroring unavailable; falling back to main display capture")
                            lastVirtualDisplayError = MirageError.protocolError("Display mirroring target did not stabilize")
                            await disableDisplayMirroring(displayID: context.displayID)
                            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
                            desktopVirtualDisplayID = nil
                            sharedVirtualDisplayGeneration = 0
                            sharedVirtualDisplayScaleFactor = 1.0
                            desktopDisplayBounds = nil
                            desktopUsesHostResolution = requestedDesktopUsesHostResolution
                            break acquisitionLoop
                        }
                    } else {
                        await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(targetDisplayID: context.displayID)
                        logDesktopStartStep("display mirroring cleared/skipped (secondary display)")
                    }
                    try await ensureDesktopStreamSetupCanContinue(
                        clientContext: clientContext,
                        startupRequestID: startupRequestID,
                        mode: mode,
                        stage: "after display mirroring update"
                    )

                    if captureDisplay.display.displayID != context.displayID {
                        MirageLogger.error(
                            .host,
                            "Desktop capture display mismatch: capture=\(captureDisplay.display.displayID), virtual=\(context.displayID)"
                        )
                    }
                    let cadenceValidation = await SharedVirtualDisplayManager.shared.validateDisplayCadence(
                        context,
                        targetFrameRate: attempt.refreshRate
                    )
                    try await ensureDesktopStreamSetupCanContinue(
                        clientContext: clientContext,
                        startupRequestID: startupRequestID,
                        mode: mode,
                        stage: "after display cadence validation"
                    )
                    let usesDisplayRefreshCadence = cadenceValidation.usesNativeDisplayCadence
                    if !usesDisplayRefreshCadence {
                        MirageLogger.host(
                            "Desktop virtual display \(context.displayID) did not prove \(attempt.refreshRate)Hz live cadence; using explicit SCK frame interval"
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
                        colorSpace: captureDisplayColorSpace,
                        captureSource: .virtualDisplay,
                        allowsClientResize: true,
                        presentationResolution: captureResolution,
                        virtualDisplaySnapshot: context,
                        usesDisplayRefreshCadence: usesDisplayRefreshCadence
                    )
                    virtualDisplayStartupSession.persistIfPreferred(
                        from: context,
                        attemptedRefreshRate: attempt.refreshRate
                    )
                    break acquisitionLoop
                } catch is DesktopVirtualDisplayStartupBudgetExceeded {
                    lastVirtualDisplayError = DesktopVirtualDisplayStartupBudgetExceeded()
                    await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
                    desktopVirtualDisplayID = nil
                    sharedVirtualDisplayGeneration = 0
                    sharedVirtualDisplayScaleFactor = 1.0
                    desktopDisplayBounds = nil
                    desktopUsesHostResolution = requestedDesktopUsesHostResolution
                    MirageLogger.host(
                        "Desktop virtual display startup exceeded 10s budget after \(startupBudget.elapsedMilliseconds)ms"
                    )
                    break acquisitionLoop
                } catch {
                    if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: startupRequestID)
                        || disconnectingClientIDs.contains(clientContext.client.id)
                        || clientsByID[clientContext.client.id] == nil {
                        throw error
                    }
                    let failureClass = virtualDisplayStartupSession.recordFailure(error)
                    await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
                    desktopVirtualDisplayID = nil
                    sharedVirtualDisplayGeneration = 0
                    sharedVirtualDisplayScaleFactor = 1.0
                    desktopDisplayBounds = nil
                    desktopUsesHostResolution = requestedDesktopUsesHostResolution
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
            try await ensureDesktopStreamSetupCanContinue(
                clientContext: clientContext,
                startupRequestID: startupRequestID,
                mode: mode,
                stage: "after main display fallback acquisition"
            )
            desktopVirtualDisplayID = nil
            desktopPrimaryPhysicalDisplayID = fallback.displayID
            desktopPrimaryPhysicalBounds = fallback.bounds
            desktopDisplayBounds = fallback.bounds
            desktopMirroredVirtualResolution = fallback.resolution
            sharedVirtualDisplayGeneration = 0
            sharedVirtualDisplayScaleFactor = fallback.scaleFactor
            desktopUsesHostResolution = true
            desktopCaptureSource = .mainDisplayFallback
            let fallbackPresentationResolution = aspectFitPixelSize(
                contentSize: fallback.resolution,
                containerSize: virtualDisplayResolution
            )
            if mode == .unified {
                let mirroringConfigured = await setupDisplayMirroring(
                    targetDisplayID: fallback.displayID,
                    expectedPixelResolution: fallback.resolution,
                    requiresResidualMirageDisplaysClear: false
                )
                if mirroringConfigured {
                    logDesktopStartStep("main display fallback mirroring configured")
                } else {
                    logDesktopStartStep("main display fallback mirroring incomplete; continuing")
                }
                try await ensureDesktopStreamSetupCanContinue(
                    clientContext: clientContext,
                    startupRequestID: startupRequestID,
                    mode: mode,
                    stage: "after main display fallback mirroring"
                )
            }
            acquiredCaptureContext = (
                display: fallback.display,
                resolution: fallback.resolution,
                p3CoverageStatus: nil,
                colorSpace: nil,
                captureSource: .mainDisplayFallback,
                allowsClientResize: false,
                presentationResolution: fallbackPresentationResolution,
                virtualDisplaySnapshot: nil,
                usesDisplayRefreshCadence: nil
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
        let captureSource = acquiredCaptureContext.captureSource
        let allowsClientResize = acquiredCaptureContext.allowsClientResize
        let presentationResolution = acquiredCaptureContext.presentationResolution
        let virtualDisplaySnapshot = acquiredCaptureContext.virtualDisplaySnapshot
        let usesDisplayRefreshCadence = acquiredCaptureContext.usesDisplayRefreshCadence
        desktopCaptureSource = captureSource

        if captureSource == .mainDisplayFallback {
            let originalFPS = config.targetFrameRate
            let fallbackFPS = min(originalFPS, 60)
            let fallbackBitrate = min(config.bitrate ?? 150_000_000, 150_000_000)
            config = config
                .withTargetFrameRate(fallbackFPS)
                .withOverrides(bitrate: fallbackBitrate)
            MirageLogger.host(
                "Desktop startup fallback profile applied for main-display capture: " +
                    "fps \(originalFPS)->\(fallbackFPS), bitrate \(fallbackBitrate)"
            )
        }

        try await ensureDesktopStreamSetupCanContinue(
            clientContext: clientContext,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "after acquisition"
        )

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
        await streamContext.configureDesktopVirtualDisplayCapture(
            snapshot: virtualDisplaySnapshot,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
        await streamContext.logBitrateContract(event: "start")
        logDesktopStartStep("stream context created (\(streamID))")
        if allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for desktop stream \(streamID)")
        }
        if !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for desktop stream \(streamID)")
        }
        let metricsClientID = clientContext.client.id
        let metricsSessionID = clientContext.sessionID
        await streamContext.setMetricsUpdateHandler { [weak self] metrics in
            self?.recordClientMediaActivity(clientID: metricsClientID)
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

        try await ensureDesktopStreamSetupCanContinue(
            clientContext: clientContext,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "before stream activation"
        )

        desktopStreamContext = streamContext
        desktopStreamID = streamID
        desktopStreamClientContext = clientContext
        desktopRequestedScaleFactor = desktopBackingScale.scaleFactor
        streamsByID[streamID] = streamContext
        notifyActiveStreamActivityChanged()
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
            await cleanupFailedDesktopStreamStartup(
                mode: mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_client_disconnected_after_audio_activation"
            )
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }
        desktopStreamClientContext = activeClientContext

        syncSharedClipboardState()
        await updateLightsOutState()
        let excludedWindows = await resolveLightsOutExcludedWindows()
        try await ensureDesktopStreamStartupCanContinue(
            streamID: streamID,
            clientSessionID: clientContext.sessionID,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "after Lights Out setup"
        )

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
        try await ensureDesktopStreamStartupCanContinue(
            streamID: streamID,
            clientSessionID: clientContext.sessionID,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "after input cache registration"
        )
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
        try await ensureDesktopStreamStartupCanContinue(
            streamID: streamID,
            clientSessionID: clientContext.sessionID,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "after video stream open"
        )

        // Start streaming the display with direct Loom send ownership in StreamPacketSender.
        let firstSuccessfulVideoPacketSent = Locked(false)
        var usedSyntheticDesktopStartupFrame = false
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

            if mode == .unified || mode == .secondary {
                var recoveryAttempted = false
                var audioReadinessFallbackAttempted = false
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
                        hasCachedStartupFrame: hasCachedStartupFrame
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
                        if shouldSeedSyntheticDesktopStartupFrame(
                            readiness: readiness,
                            recoveryAttempted: recoveryAttempted,
                            hasCachedStartupFrame: hasCachedStartupFrame
                        ) {
                            let seededSyntheticStartupFrame = await streamContext.seedSyntheticDisplayStartupFrameIfNeeded(
                                reason: "startup_capture_readiness_\(readiness.rawValue)"
                            )
                            if seededSyntheticStartupFrame {
                                usedSyntheticDesktopStartupFrame = true
                                MirageLogger.host(
                                    "Desktop start: live and screenshot startup frames unavailable after restart; " +
                                        "using synthetic startup frame"
                                )
                                continue
                            }
                        }
                        if effectiveAudioConfiguration.enabled, !audioReadinessFallbackAttempted {
                            audioReadinessFallbackAttempted = true
                            effectiveAudioConfiguration.enabled = false
                            audioConfigurationByClientID[clientContext.client.id] = effectiveAudioConfiguration
                            MirageLogger.host(
                                "Desktop start: capture readiness \(readiness.rawValue); retrying startup readiness without audio"
                            )
                            await stopAudioPipeline(for: clientContext.client.id, reason: .error)
                            await closeAudioTransportIfNeeded(for: clientContext.client.id)
                            await streamContext.setCapturedAudioHandler(nil)
                            await streamContext.restartDisplayCaptureForStartupRecovery(
                                reason: "startup_capture_readiness_audio_fallback_\(readiness.rawValue)"
                            )
                            recoveryAttempted = false
                            continue
                        }
                        throw MirageError.protocolError(
                            "\(mode.displayName) desktop startup failed waiting for first display sample (\(readiness.rawValue))"
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
        try await ensureDesktopStreamStartupCanContinue(
            streamID: streamID,
            clientSessionID: clientContext.sessionID,
            startupRequestID: startupRequestID,
            mode: mode,
            stage: "before desktopStreamStarted"
        )

        // Send stream-started to client BEFORE enabling encoding so the client's
        // controller/reassembler is ready when video packets arrive.
        // (Window streams already follow this order — see MirageHostService+Streams.swift.)
        let dimensionToken = await streamContext.getDimensionToken()
        let startedDisplayResolution = await currentDesktopStartedResolution(fallback: captureResolution)
        let targetFrameRate = await streamContext.getTargetFrameRate()
        let codec = await streamContext.getCodec()
        let acceptedMediaMaxPacketSize = await streamContext.getMediaMaxPacketSize()
        let startupAttemptID = UUID()
        desktopPresentationGeneration &+= 1
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
            transitionPhase: .startup,
            desktopPresentationGeneration: desktopPresentationGeneration,
            captureSource: captureSource,
            allowsClientResize: allowsClientResize,
            presentationWidth: Int(presentationResolution.width.rounded()),
            presentationHeight: Int(presentationResolution.height.rounded())
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
        if usedSyntheticDesktopStartupFrame {
            scheduleSyntheticDesktopStartupCaptureRecovery(
                streamContext: streamContext,
                streamID: streamID
            )
        }
        clearDesktopStartupMarkerOnExit = false
    }

    private func scheduleSyntheticDesktopStartupCaptureRecovery(
        streamContext: StreamContext,
        streamID: StreamID
    ) {
        Task { @MainActor [weak self, streamContext] in
            for attempt in 1...desktopSyntheticStartupRecoveryMaxAttempts {
                do {
                    try await Task.sleep(for: desktopSyntheticStartupRecoveryAttemptInterval)
                } catch {
                    return
                }

                guard let self,
                      self.desktopStreamID == streamID,
                      self.desktopStreamContext != nil else {
                    return
                }
                guard !(await streamContext.hasObservedDisplayStartupSample()) else {
                    MirageLogger.host(
                        "Desktop start: live display sample arrived after synthetic startup frame"
                    )
                    return
                }

                MirageLogger.host(
                    "Desktop start: synthetic startup frame still waiting for live display sample; " +
                        "restarting display capture attempt \(attempt)/\(desktopSyntheticStartupRecoveryMaxAttempts)"
                )
                await streamContext.restartDisplayCaptureForStartupRecovery(
                    reason: "synthetic_startup_live_sample_recovery_\(attempt)"
                )
            }

            do {
                try await Task.sleep(for: desktopSyntheticStartupRecoveryAttemptInterval)
            } catch {
                return
            }

            guard let self,
                  self.desktopStreamID == streamID,
                  self.desktopStreamContext != nil,
                  !(await streamContext.hasObservedDisplayStartupSample()) else {
                return
            }
            MirageLogger.host(
                "Desktop start: synthetic startup frame recovery exhausted; stream health monitoring will continue"
            )
        }
    }

    private func ensureDesktopStreamStartupCanContinue(
        streamID: StreamID,
        clientSessionID: UUID,
        startupRequestID: UUID,
        mode: MirageDesktopStreamMode,
        stage: String
    )
    async throws {
        if isStreamSetupCancelled(clientSessionID: clientSessionID, startupRequestID: startupRequestID) {
            MirageLogger.host("Desktop stream setup cancelled by client \(stage)")
            if desktopStreamID == streamID {
                await cleanupFailedDesktopStreamStartup(
                    mode: mode,
                    deferDisplayTeardown: true,
                    cleanupReason: "desktop_startup_cancelled_\(stage)"
                )
            }
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }

        guard desktopStreamID == streamID, desktopStreamContext != nil else {
            MirageLogger.host("Desktop stream startup stopped \(stage)")
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }
    }

    private func ensureDesktopStreamSetupCanContinue(
        clientContext: ClientContext,
        startupRequestID: UUID,
        mode: MirageDesktopStreamMode,
        stage: String
    )
    async throws {
        if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: startupRequestID) {
            MirageLogger.host("Desktop stream setup cancelled by client \(stage)")
            await cleanupFailedDesktopStreamStartup(
                mode: mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_cancelled_\(stage)"
            )
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }

        guard !disconnectingClientIDs.contains(clientContext.client.id),
              clientsByID[clientContext.client.id] != nil else {
            MirageLogger.host("Desktop stream client disconnected \(stage); aborting startup")
            await cleanupFailedDesktopStreamStartup(
                mode: mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_client_disconnected_\(stage)"
            )
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }
    }

    /// Clean up virtual display and mirroring state after a failed desktop stream startup.
    private func cleanupFailedDesktopStreamStartup(
        mode: MirageDesktopStreamMode,
        deferDisplayTeardown: Bool = false,
        cleanupReason: String = "failed_desktop_startup_cleanup"
    ) async {
        let failedStreamID = desktopStreamID
        let failedContext = desktopStreamContext
        let failedVirtualDisplayID = desktopVirtualDisplayID
        let failedPrimaryDisplayID = desktopPrimaryPhysicalDisplayID

        if let failedStreamID {
            cancelPendingStartupAttempt(streamID: failedStreamID)
            streamsByID.removeValue(forKey: failedStreamID)
            unregisterStallWindowPointerRoute(streamID: failedStreamID)
            streamStartupBaseTimes.removeValue(forKey: failedStreamID)
            streamStartupRegistrationLogged.remove(failedStreamID)
            transportSendErrorReported.remove(failedStreamID)
            if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: failedStreamID) {
                Task { try? await videoStream.close() }
            }
            transportRegistry.unregisterVideoStream(streamID: failedStreamID)
            inputStreamCacheActor.remove(failedStreamID)
        }

        desktopStreamContext = nil
        desktopStreamClientContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopRequestedScaleFactor = nil
        notifyActiveStreamActivityChanged()
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
        if let failedContext {
            await failedContext.stop()
        }
        if let failedStreamID {
            await deactivateAudioSourceIfNeeded(streamID: failedStreamID)
        }
        if deferDisplayTeardown {
            scheduleDeferredDesktopStartupDisplayCleanup(
                mode: mode,
                failedVirtualDisplayID: failedVirtualDisplayID,
                failedPrimaryDisplayID: failedPrimaryDisplayID,
                reason: cleanupReason
            )
        } else {
            if let vdID = failedVirtualDisplayID {
                if mode == .unified {
                    await disableDisplayMirroring(displayID: vdID)
                }
                await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
            } else if !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: failedPrimaryDisplayID ?? CGMainDisplayID())
            }
        }
        desktopVirtualDisplayID = nil
        desktopDisplayBounds = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopPhysicalDisplayTopologySignature = nil
        desktopMirroredVirtualResolution = nil
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = 1.0
        desktopUsesHostResolution = false
        desktopCaptureSource = .virtualDisplay
        resetDesktopClientFitFallbackState()
        mirroredDesktopDisplayIDs.removeAll()
        if !deferDisplayTeardown {
            await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: cleanupReason)
        }
        await syncAppListRequestDeferralForInteractiveWorkload()
        if !deferDisplayTeardown {
            await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        }
        await updateLightsOutState()
        if activeStreams.isEmpty, desktopStreamID == nil {
            await PowerAssertionManager.shared.disable()
        }
    }

    private func scheduleDeferredDesktopStartupDisplayCleanup(
        mode: MirageDesktopStreamMode,
        failedVirtualDisplayID: CGDirectDisplayID?,
        failedPrimaryDisplayID: CGDirectDisplayID?,
        reason: String
    ) {
        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            await self.performDeferredDesktopStartupDisplayCleanup(
                mode: mode,
                failedVirtualDisplayID: failedVirtualDisplayID,
                failedPrimaryDisplayID: failedPrimaryDisplayID,
                reason: reason
            )
        }
    }

    private func performDeferredDesktopStartupDisplayCleanup(
        mode: MirageDesktopStreamMode,
        failedVirtualDisplayID: CGDirectDisplayID?,
        failedPrimaryDisplayID: CGDirectDisplayID?,
        reason: String
    ) async {
        guard desktopStreamID == nil, desktopStreamContext == nil else {
            MirageLogger.host("Skipped deferred desktop display cleanup because a newer desktop stream is active")
            deferredDesktopStartupDisplayCleanupTask = nil
            return
        }

        if let vdID = failedVirtualDisplayID {
            if mode == .unified {
                await disableDisplayMirroring(displayID: vdID)
            }
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        } else if !desktopMirroringSnapshot.isEmpty {
            await disableDisplayMirroring(displayID: failedPrimaryDisplayID ?? CGMainDisplayID())
        }
        await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: reason)
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        deferredDesktopStartupDisplayCleanupTask = nil
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
        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = nil

        let stoppedDesktopSessionID = desktopSessionID
        let stoppedClientContext = desktopStreamClientContext
        let stoppedContext = desktopStreamContext
        let stoppedMode = desktopStreamMode
        let stoppedPrimaryDisplayID = desktopPrimaryPhysicalDisplayID
        MirageLogger.host(
            "Stopping desktop stream: streamID=\(streamID), session=\(stoppedDesktopSessionID?.uuidString ?? "nil"), reason=\(reason)"
        )
        beginDesktopSharedDisplayTransition()
        defer { endDesktopSharedDisplayTransition() }
        resetDesktopResizeTransactionState()
        desktopDisplayTopologyRefreshTask?.cancel()
        desktopDisplayTopologyRefreshTask = nil

        let sharedDisplayID = await SharedVirtualDisplayManager.shared.getDisplayID()

        cancelPendingStartupAttempt(streamID: streamID)
        desktopStreamContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopStreamClientContext = nil
        notifyActiveStreamActivityChanged()
        streamsByID.removeValue(forKey: streamID)
        unregisterStallWindowPointerRoute(streamID: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupRegistrationLogged.remove(streamID)
        transportSendErrorReported.remove(streamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            Task { try? await videoStream.close() }
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
        inputStreamCacheActor.remove(streamID)

        if let stoppedContext { await stoppedContext.stop() }

        if stoppedMode == .unified {
            if let sharedDisplayID {
                await disableDisplayMirroring(displayID: sharedDisplayID)
            } else if !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: stoppedPrimaryDisplayID ?? CGMainDisplayID())
            }
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

        desktopDisplayBounds = nil
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopMirroredVirtualResolution = nil
        desktopRequestedScaleFactor = nil
        desktopUsesHostResolution = false
        desktopCaptureSource = .virtualDisplay
        resetDesktopClientFitFallbackState()
        sharedVirtualDisplayScaleFactor = 2.0
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
        await deactivateAudioSourceIfNeeded(streamID: streamID)

        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: "desktop_stream_stop")

        if activeStreams.isEmpty { await PowerAssertionManager.shared.disable() }

        await syncAppListRequestDeferralForInteractiveWorkload()
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()

        syncSharedClipboardState()
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
    func findSCDisplayWithRetry(
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil,
        expectedPixelResolution: CGSize? = nil
    )
    async throws -> SCDisplayWrapper {
        let resolvedAttempts = max(maxAttempts, 12)
        do {
            let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                maxAttempts: resolvedAttempts,
                startupBudget: startupBudget,
                expectedPixelResolution: expectedPixelResolution
            )
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

    func waitForDesktopTransitionCaptureReadiness(
        context: StreamContext,
        label: String,
        timeout: Duration = .milliseconds(900)
    )
    async throws {
        let readiness = await context.waitForDisplayStartupReadiness(timeout: timeout)
        let hasCachedTransitionFrame = await context.hasCachedDesktopResizeFrame()
        switch readiness {
        case .usableFrameSeen, .idleFrameSeen:
            MirageLogger.host(
                "Desktop transition capture readiness satisfied for \(label): \(readiness.rawValue)"
            )
        case .noScreenSamples where hasCachedTransitionFrame:
            MirageLogger.host(
                "Desktop transition capture readiness using cached post-transition frame for \(label)"
            )
        case .blankOrSuspendedOnly, .noScreenSamples:
            MirageLogger.error(
                .host,
                "Desktop transition capture readiness failed for \(label): \(readiness.rawValue)"
            )
            throw MirageError.protocolError(
                "Desktop transition capture did not produce a usable frame (\(readiness.rawValue))"
            )
        }
    }

    func mainDisplayFallbackEligibility(
        displayID: CGDirectDisplayID,
        isVirtualDisplay: (CGDirectDisplayID) -> Bool = { CGVirtualDisplayBridge.isVirtualDisplay($0) }
    )
    -> Bool {
        !isVirtualDisplay(displayID)
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
        guard mainDisplayFallbackEligibility(displayID: displayID) else {
            MirageLogger.error(
                .host,
                "Desktop main-display fallback rejected because display \(displayID) is virtual/headless (reason=\(reason))"
            )
            throw MirageError.protocolError("Main display fallback requires a physical display")
        }
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

    func mergeDisplayMirroringSnapshot(for displayIDs: [CGDirectDisplayID]) {
        let snapshot = captureDisplayMirroringSnapshot(for: displayIDs)
        var insertedCount = 0
        for (displayID, mirroredDisplayID) in snapshot where desktopMirroringSnapshot[displayID] == nil {
            desktopMirroringSnapshot[displayID] = mirroredDisplayID
            insertedCount += 1
        }
        if insertedCount > 0 {
            MirageLogger.host(
                "Captured display mirroring snapshot for \(insertedCount) additional display(s); total=\(desktopMirroringSnapshot.count)"
            )
        }
    }

    @discardableResult
    func restoreDisplaySpaceSnapshotIfNeeded(
        reason: String,
        maxAttempts: Int = 3
    )
    async -> Bool {
        guard !desktopDisplaySpaceSnapshot.isEmpty else { return true }

        for attempt in 1 ... maxAttempts {
            let pending = pendingDisplaySpaceRestores(
                snapshot: desktopDisplaySpaceSnapshot,
                currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
            )
            if pending.isEmpty { return true }

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

        var unresolved = pendingDisplaySpaceRestores(
            snapshot: desktopDisplaySpaceSnapshot,
            currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
        )
        if !unresolved.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
            unresolved = pendingDisplaySpaceRestores(
                snapshot: desktopDisplaySpaceSnapshot,
                currentSpaceProvider: { CGSWindowSpaceBridge.getCurrentSpaceForDisplay($0) }
            )
        }
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
            let message = "Display current Space restore remained incomplete after delayed verification " +
                "(reason=\(reason), attempts=\(maxAttempts)): \(unresolvedSummary)"
            if reason.hasPrefix("mirroring_disable") {
                MirageLogger.host(message)
            } else {
                MirageLogger.error(.host, message)
            }
            return false
        }
        return true
    }

    func finishDesktopSpaceRestoreAfterDisplayTeardown(reason: String) async {
        guard !desktopDisplaySpaceSnapshot.isEmpty else { return }

        for attempt in 1 ... 3 {
            let restored = await restoreDisplaySpaceSnapshotIfNeeded(
                reason: "\(reason)_post_teardown_\(attempt)",
                maxAttempts: 4
            )
            if restored {
                desktopDisplaySpaceSnapshot.removeAll()
                return
            }
            try? await Task.sleep(for: .milliseconds(Int64(250 * attempt)))
        }

        MirageLogger.host(
            "Retaining unresolved display Space snapshot for future cleanup (reason=\(reason), displays=\(desktopDisplaySpaceSnapshot.keys.sorted()))"
        )
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
    func unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(
        targetDisplayID: CGDirectDisplayID? = nil
    )
    async {
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
            if let targetDisplayID, mirroredDisplayID != targetDisplayID {
                return nil
            }
            return displayID
        }

        guard !physicalDisplaysMirroringVirtual.isEmpty else { return }

        await withHostDisplayMutation(kind: .displayMirroring) {
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
    }

    /// Set up display mirroring so every non-Mirage display mirrors the target display.
    /// Normal desktop streams target the shared virtual display; host-resolution streams target the main display.
    @discardableResult
    func setupDisplayMirroring(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize? = nil,
        requiresResidualMirageDisplaysClear: Bool = true
    )
    async -> Bool {
        guard await waitForDisplayMirroringTargetStability(
            targetDisplayID: targetDisplayID,
            expectedPixelResolution: expectedPixelResolution,
            requiresResidualMirageDisplaysClear: requiresResidualMirageDisplaysClear
        ) else {
            MirageLogger.host(
                "Display mirroring setup deferred because target display \(targetDisplayID) did not stabilize"
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
            mergeDisplayMirroringSnapshot(for: displaysToMirror)
            mirroredDesktopDisplayIDs.formUnion(displaysToMirror)
            MirageLogger.host("Display mirroring already enabled for \(displaysToMirror.count) displays")
            await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup_noop")
            return true
        }

        mergeDisplayMirroringSnapshot(for: displaysToMirror)

        MirageLogger.host("Setting up mirroring for \(displaysToMirror.count) displays")

        return await withHostDisplayMutation(kind: .displayMirroring) {
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
                    MirageLogger.host("Configured display \(displayID) to mirror target display \(targetDisplayID)")
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

            mirroredDesktopDisplayIDs.formUnion(successfullyMirrored)
            MirageLogger
                .host(
                    "Display mirroring enabled for \(successfullyMirrored.count) displays → target display \(targetDisplayID)"
                )
            await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_setup")
            return successfullyMirrored.count == displaysToMirror.count
        }
    }

    private func waitForDisplayMirroringTargetStability(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize?,
        requiresResidualMirageDisplaysClear: Bool = true,
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
                expectedTargetPixelResolution: expectedPixelResolution,
                requiresResidualMirageDisplaysClear: requiresResidualMirageDisplaysClear
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

        mergeDisplayMirroringSnapshot(for: displaysToMirror)

        let mirroredToTarget = displaysToMirror.filter { CGDisplayMirrorsDisplay($0) == targetDisplayID }
        guard !mirroredToTarget.isEmpty else { return }

        await withHostDisplayMutation(kind: .displayMirroring) {
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
    }

    /// Restore display mirroring to the pre-stream configuration.
    @discardableResult
    func disableDisplayMirroring(displayID: CGDirectDisplayID) async -> Bool {
        var restoreTargets = desktopMirroringSnapshot
        for mirroredDisplayID in mirroredDesktopDisplayIDs where restoreTargets[mirroredDisplayID] == nil {
            restoreTargets[mirroredDisplayID] = kCGNullDirectDisplay
        }

        guard !restoreTargets.isEmpty else {
            MirageLogger.host("No display mirroring snapshot or tracked mirrored displays to restore")
            mirroredDesktopDisplayIDs.removeAll()
            let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_no_snapshot")
            if restored {
                desktopDisplaySpaceSnapshot.removeAll()
            }
            return restored
        }

        captureDisplaySpaceSnapshot(
            for: restoreTargets.keys.sorted(),
            overwriteExisting: false
        )

        MirageLogger
            .host("Restoring \(restoreTargets.count) displays from mirroring (virtual display \(displayID))")

        return await withHostDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                MirageLogger.host("Display mirroring restore unavailable: failed to begin display configuration")
                return false
            }

            var successfullyRestored = 0

            var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            var onlineCount: UInt32 = 0
            CGGetOnlineDisplayList(16, &onlineIDs, &onlineCount)
            let onlineDisplays = Set(onlineIDs.prefix(Int(onlineCount)))
            for (displayID, mirroredDisplayID) in restoreTargets {
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
                    return false
                } else {
                    MirageLogger.host("Display mirroring disabled for \(successfullyRestored) displays")
                    let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable")
                    mirroredDesktopDisplayIDs.removeAll()
                    desktopMirroringSnapshot.removeAll()
                    if restored {
                        desktopDisplaySpaceSnapshot.removeAll()
                    }
                    return restored
                }
            } else {
                CGCancelDisplayConfiguration(config)
                let restored = await restoreDisplaySpaceSnapshotIfNeeded(reason: "mirroring_disable_noop")
                mirroredDesktopDisplayIDs.removeAll()
                desktopMirroringSnapshot.removeAll()
                if restored {
                    desktopDisplaySpaceSnapshot.removeAll()
                }
                return restored
            }
        }
    }

    private func withHostDisplayMutation<T>(
        kind: VirtualDisplayMutationKind,
        operation: () async -> T
    ) async -> T {
        let lease = await VirtualDisplayMutationCoordinator.shared.acquire(kind: kind)
        let result = await operation()
        await VirtualDisplayMutationCoordinator.shared.release(lease)
        return result
    }
}

#endif
