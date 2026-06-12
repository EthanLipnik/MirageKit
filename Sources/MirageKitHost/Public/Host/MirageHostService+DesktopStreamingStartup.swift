//
//  MirageHostService+DesktopStreamingStartup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Verifies that the requesting client can still own a new desktop stream.
    func prepareForDesktopStreamStart(clientContext: ClientContext) async throws {
        guard findClientContext(sessionID: clientContext.sessionID)?.client.id == clientContext.client.id else {
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }

        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = nil
        cancelDeferredDesktopDisplayCleanupForReuse(reason: "new_desktop_stream_start")

        if let currentOwnerClientID = desktopStreamClientContext?.client.id,
           desktopStreamContext != nil,
           disconnectingClientIDs.contains(currentOwnerClientID) || clientsByID[currentOwnerClientID] == nil {
            MirageLogger.host(
                "Cleaning up desktop stream owned by a disconnected client before accepting a new desktop stream request"
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
        }

        if desktopStreamContext != nil, desktopStreamID == nil {
            MirageLogger.host("Cleaning up partial desktop startup state before accepting a new desktop stream request")
            await cleanupFailedDesktopStreamStartup(mode: desktopStreamMode)
        }

        guard desktopStreamContext == nil else {
            throw MirageError.protocolError("Desktop stream already active")
        }
        guard mediaSecurityByClientID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for desktop stream client")
        }
    }

    /// Logs when the negotiated color depth is lower than the client requested.
    nonisolated func logDesktopColorDepthDowngradeIfNeeded(
        requested: MirageStreamColorDepth?,
        resolved: MirageStreamColorDepth?
    ) {
        if let requested, let resolved, requested != resolved {
            MirageLogger.host(
                "Desktop color depth request downgraded: requested=\(requested.displayName), effective=\(resolved.displayName)"
            )
        }
    }

    /// Emits the resolved desktop stream start resolution and mode.
    nonisolated func logDesktopStartRequest(
        displayResolution: CGSize,
        virtualDisplayResolution: CGSize,
        resolvedClientScaleFactor: CGFloat?,
        mode: MirageDesktopStreamMode
    ) {
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
    }

    /// Records runtime feature toggles that affect desktop stream quality.
    nonisolated func logDesktopStreamRuntimeOptions(
        streamID: StreamID,
        allowRuntimeQualityAdjustment: Bool?,
        lowLatencyHighResolutionCompressionBoost: Bool
    ) {
        if allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for desktop stream \(streamID)")
        }
        if !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for desktop stream \(streamID)")
        }
    }

    /// Creates and configures the stream context used for desktop video transport.
    func makeDesktopStreamContext(
        _ request: DesktopStreamContextRequest
    ) async -> StreamContext {
        streamStartupBaseTimes[request.streamID] = request.desktopStartTime
        streamStartupRegistrationLogged.remove(request.streamID)
        transportSendErrorReported.remove(request.streamID)
        let streamContext = StreamContext(
            streamID: request.streamID,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: request.config,
            streamScale: request.streamScale,
            requestedAudioChannelCount: request.audioConfiguration.channelLayout.channelCount,
            maxPacketSize: request.mediaMaxPacketSize,
            mediaSecurityContext: nil,
            additionalFrameFlags: [.desktopStream],
            runtimeQualityAdjustmentEnabled: request.allowRuntimeQualityAdjustment ?? true,
            encoderCatchUpQualityAdjustmentEnabled: request.allowEncoderCatchUpQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: request.lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: request.disableResolutionCap,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: request.capturePressureProfile,
            latencyMode: request.latencyMode,
            hostBufferingPolicy: request.hostBufferingPolicy,
            transportPathKind: request.transportPathKind,
            mediaPathProfile: request.mediaPathProfile,
            mediaPathDiagnosticSummary: request.mediaPathDiagnosticSummary,
            enteredBitrate: request.enteredBitrate,
            bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
            encoderMaxWidth: request.encoderMaxWidth,
            encoderMaxHeight: request.encoderMaxHeight,
            captureShowsCursor: request.cursorPresentation.capturesHostCursor
        )
        await streamContext.setHostAdaptiveDesktopGeometryUpdateHandler { [weak self] streamID in
            await self?.sendStreamScaleUpdate(streamID: streamID)
        }
        await streamContext.setStartupBaseTime(request.desktopStartTime, label: "desktop stream \(request.streamID)")
        if let captureDisplayP3CoverageStatus = request.captureDisplayP3CoverageStatus {
            await streamContext.setDisplayP3CoverageStatusOverride(captureDisplayP3CoverageStatus)
        }
        await streamContext.configureDesktopVirtualDisplayCapture(
            snapshot: request.virtualDisplaySnapshot,
            usesDisplayRefreshCadence: request.usesDisplayRefreshCadence
        )
        await streamContext.logBitrateContract(event: "start")
        return streamContext
    }

    /// Stores desktop stream ownership and reset state before display setup begins.
    func beginDesktopStreamStartupState(
        streamID: StreamID,
        desktopSessionID: UUID,
        mode: MirageDesktopStreamMode,
        cursorPresentation: MirageDesktopCursorPresentation,
        usesHostResolution: Bool,
        virtualDisplayResolution: CGSize
    ) async {
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation
        desktopUsesHostResolution = usesHostResolution
        desktopCaptureSource = .virtualDisplay
        self.desktopSessionID = desktopSessionID
        desktopPresentationGeneration = 0
        resetDesktopResizeTransactionState()
        await HostDesktopStreamTerminationTracker.shared.markDesktopDisplaySetupStarted(
            streamID: streamID,
            requestedPixelResolution: virtualDisplayResolution
        )
    }

    /// Applies conservative encoder limits when startup falls back to main-display capture.
    nonisolated func applyMainDisplayFallbackProfileIfNeeded(
        captureSource: MirageDesktopCaptureSource,
        config: inout MirageEncoderConfiguration
    ) {
        guard captureSource == .mainDisplayFallback else { return }

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

    /// Marks desktop stream startup as complete after capture has begun.
    func finishDesktopStreamStartup(
        streamID: StreamID,
        startedDisplayResolution: CGSize,
        captureResolution: CGSize
    ) async {
        MirageLogger
            .host(
                "Desktop stream started: streamID=\(streamID), resolution=\(Int(startedDisplayResolution.width))x\(Int(startedDisplayResolution.height))"
            )
        await HostDesktopStreamTerminationTracker.shared.markDesktopStreamStarted(
            streamID: streamID,
            requestedPixelResolution: captureResolution
        )
    }

    /// Resolves desktop audio settings for the selected desktop stream mode.
    nonisolated func resolvedDesktopAudioConfiguration(
        _ audioConfiguration: MirageAudioConfiguration,
        mode: MirageDesktopStreamMode
    ) -> MirageAudioConfiguration {
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
        return resolvedAudioConfiguration
    }

    /// Stops incompatible workloads and prepares host input state for desktop capture.
    func prepareDesktopStreamWorkload(logDesktopStartStep: (String) -> Void) async {
        await stopAllStreamsForDesktopMode()
        logDesktopStartStep("other streams stopped")
        await syncAppListRequestDeferralForInteractiveWorkload()
        inputController.clearAllModifiers()
    }

    /// Logs desktop downscaling when the stream scale is below native resolution.
    nonisolated func logDesktopStreamScale(
        _ streamScale: CGFloat,
        virtualDisplayResolution: CGSize
    ) {
        guard streamScale < 1.0 else { return }
        MirageLogger.host(
            "Desktop scale \(streamScale) → capture/encoder downscale; virtual display stays at " +
                "\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px"
        )
    }

    /// Builds the encoder configuration for a desktop stream start request.
    func configuredDesktopEncoder(
        _ request: DesktopEncoderConfigurationRequest
    ) -> MirageEncoderConfiguration {
        var config = encoderConfig.withOverrides(
            keyFrameInterval: request.keyFrameInterval,
            colorDepth: request.colorDepth,
            captureQueueDepth: request.captureQueueDepth,
            bitrate: request.bitrate
        )
        if let codec = request.codec { config.codec = codec }

        config.bitrate = Self.resolvedDesktopEncoderBitrate(requestedBitrate: config.bitrate)

        if let upscalingMode = request.upscalingMode, upscalingMode != .off, request.codec != .proRes4444 {
            config.applyUpscalingPixelFormat()
            MirageLogger.host("Applying BGRA pixel format for MetalFX \(upscalingMode.displayName) upscaling (desktop stream)")
        }
        if let targetFrameRate = request.targetFrameRate { config = config.withTargetFrameRate(targetFrameRate) }
        if request.disableResolutionCap {
            MirageLogger.host("Desktop stream resolution cap disabled")
        }
        MirageLogger.host("Desktop stream latency mode: \(request.latencyMode.displayName)")
        return config
    }

    /// Relays stream metrics from the desktop media context to the owning client.
    func configureDesktopMetricsHandler(
        _ streamContext: StreamContext,
        clientContext: ClientContext
    ) async {
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
    }
}

#endif
