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

extension MirageHostService {
    /// Normalizes a requested desktop bitrate. The user's chosen bitrate is
    /// honored literally as the client ceiling; HEVC streams may start below it
    /// and climb as the host proves encoder and transport headroom.
    nonisolated static func resolvedDesktopEncoderBitrate(requestedBitrate: Int?) -> Int? {
        MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: requestedBitrate)
    }

/// Start streaming the desktop (unified or secondary display mode)
/// This stops any active app/window streams for mutual exclusivity
func startDesktopStream(
    to clientContext: ClientContext,
    displayResolution: CGSize,
    clientScaleFactor: CGFloat? = nil,
    mode: MirageDesktopStreamMode,
    cursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor,
    usesHostResolution: Bool,
    keyFrameInterval: Int?,
    colorDepth: MirageStreamColorDepth?,
    captureQueueDepth: Int?,
    enteredBitrate: Int?,
    bitrate: Int?,
    latencyMode: MirageStreamLatencyMode = .lowestLatency,
    hostBufferingPolicy: MirageHostBufferingPolicy = .freshestFrame,
    hostBufferDepth: MirageHostBufferDepth = .standard,
    allowRuntimeQualityAdjustment: Bool?,
    allowEncoderCatchUpQualityAdjustment: Bool?,
    disableResolutionCap: Bool,
    streamScale: CGFloat?,
    audioConfiguration: MirageAudioConfiguration,
    targetFrameRate: Int? = nil,
    bitrateAdaptationCeiling: Int? = nil,
    compressionQualityCeiling: Float? = nil,
    encoderMaxWidth: Int? = nil,
    encoderMaxHeight: Int? = nil,
    mediaMaxPacketSize: Int = mirageDefaultMaxPacketSize,
    mediaPathPolicy: MirageEffectiveMediaPathPolicy,
    upscalingMode: MirageUpscalingMode? = nil,
    codec: MirageVideoCodec? = nil,
    startupRequestID: UUID,
    desktopGeometryContractID: UUID? = nil,
    desktopGeometrySceneIdentity: String? = nil,
    desktopGeometryRefreshTargetHz: Int? = nil,
    presentationRole: MirageDesktopPresentationRole? = nil,
    associatedAppSessionID: UUID? = nil,
    associatedAppStartupRequestID: UUID? = nil,
    associatedBundleIdentifier: String? = nil
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

    try await prepareForDesktopStreamStart(clientContext: clientContext)

    let desktopStartTime = CFAbsoluteTimeGetCurrent()
    func logDesktopStartStep(_ step: String) {
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - desktopStartTime) * 1000)
        MirageLogger.host("Desktop start: \(step) (+\(deltaMs)ms)")
    }

    let resolvedAudioConfiguration = resolvedDesktopAudioConfiguration(audioConfiguration, mode: mode)

    let resolvedClientScaleFactor: CGFloat? = if let clientScaleFactor, clientScaleFactor > 0 {
        max(1.0, clientScaleFactor)
    } else {
        nil
    }
    let clampedStreamScale = StreamContext.clampStreamScale(streamScale ?? 1.0)
    let defaultDesktopBackingScale = resolvedClientScaleFactor ?? max(1.0, sharedVirtualDisplayScaleFactor)
    let requestedDesktopTargetFrameRate = max(1, targetFrameRate ?? encoderConfig.targetFrameRate)
    let effectiveDesktopTargetFrameRate = MirageAwdlMediaController.fixedDisplayTargetFrameRate(
        requestedFrameRate: requestedDesktopTargetFrameRate,
        mediaPathProfile: mediaPathPolicy.mediaPathProfile
    )
    if effectiveDesktopTargetFrameRate != requestedDesktopTargetFrameRate {
        MirageLogger.host(
            "AWDL media policy overriding requested desktop refresh " +
                "\(requestedDesktopTargetFrameRate) -> \(effectiveDesktopTargetFrameRate)"
        )
    }
    let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(
        for: effectiveDesktopTargetFrameRate
    )
    let resolvedCodec = effectiveVideoCodec(for: codec)
    let resolvedColorDepth = effectiveColorDepth(for: colorDepth, codec: resolvedCodec)
    let requestedDesktopBackingScale = resolvedDesktopBackingScaleResolution(
        logicalResolution: displayResolution,
        defaultScaleFactor: defaultDesktopBackingScale
    )
    logDesktopColorDepthDowngradeIfNeeded(requested: colorDepth, resolved: resolvedColorDepth)
    let virtualDisplayStartupPlan = desktopVirtualDisplayStartupPlan(
        logicalResolution: displayResolution,
        requestedScaleFactor: requestedDesktopBackingScale.scaleFactor,
        requestedRefreshRate: virtualDisplayRefreshRate,
        requestedColorDepth: resolvedColorDepth ?? encoderConfig.colorDepth,
        requestedColorSpace: encoderConfig.withOverrides(
            keyFrameInterval: keyFrameInterval,
            colorDepth: resolvedColorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        ).withTargetFrameRate(effectiveDesktopTargetFrameRate).colorSpace,
        requestedStreamScale: clampedStreamScale
    )
    let virtualDisplayStartupAttempts = virtualDisplayStartupPlan.attempts
    var virtualDisplayStartupSession = DesktopVirtualDisplayStartupSession(plan: virtualDisplayStartupPlan)
    let desktopBackingScale = virtualDisplayStartupAttempts.first?.backingScale ??
        requestedDesktopBackingScale
    let virtualDisplayResolution = desktopBackingScale.pixelResolution
    logDesktopStartRequest(
        displayResolution: displayResolution,
        virtualDisplayResolution: virtualDisplayResolution,
        resolvedClientScaleFactor: resolvedClientScaleFactor,
        mode: mode
    )
    logDesktopStartStep("request accepted")

    await prepareDesktopStreamWorkload(logDesktopStartStep: logDesktopStartStep)
    let desktopSessionID = UUID()
    let streamID = nextStreamID
    nextStreamID += 1
    var retainMediaPathClientEvidence = false
    mediaPathClientEvidenceByStreamID[streamID] = HostStreamMediaPathClientEvidence(policy: mediaPathPolicy)
    defer {
        if !retainMediaPathClientEvidence {
            mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
        }
    }
    await beginDesktopStreamStartupState(
        streamID: streamID,
        desktopSessionID: desktopSessionID,
        mode: mode,
        cursorPresentation: cursorPresentation,
        usesHostResolution: usesHostResolution,
        virtualDisplayResolution: virtualDisplayResolution
    )
    clearDesktopStartupMarkerOnExit = true

    var config = configuredDesktopEncoder(
        DesktopEncoderConfigurationRequest(
            keyFrameInterval: keyFrameInterval,
            colorDepth: resolvedColorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate,
            codec: resolvedCodec,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
            allowEncoderCatchUpQualityAdjustment: allowEncoderCatchUpQualityAdjustment,
            upscalingMode: upscalingMode,
            targetFrameRate: effectiveDesktopTargetFrameRate,
            disableResolutionCap: disableResolutionCap
        )
    )

    logDesktopStreamScale(clampedStreamScale, virtualDisplayResolution: virtualDisplayResolution)
    let capturePressureProfile = resolvedDesktopCapturePressureProfile()
    MirageLogger.host("Desktop capture pressure profile: \(capturePressureProfile.rawValue)")

    let acquiredCaptureContext = try await acquireDesktopCaptureContext(
        DesktopCaptureAcquisitionRequest(
            clientContext: clientContext,
            startupRequestID: startupRequestID,
            mode: mode,
            displayResolution: displayResolution,
            virtualDisplayResolution: virtualDisplayResolution,
            startupPlan: virtualDisplayStartupPlan,
            startupAttempts: virtualDisplayStartupAttempts,
            usesHostResolution: usesHostResolution
        ),
        config: &config,
        virtualDisplayStartupSession: &virtualDisplayStartupSession,
        virtualDisplaySetupGuardToken: &virtualDisplaySetupGuardToken,
        logDesktopStartStep: logDesktopStartStep
    )
    let captureDisplay = acquiredCaptureContext.display
    let captureResolution = acquiredCaptureContext.resolution
    let captureDisplayP3CoverageStatus = acquiredCaptureContext.p3CoverageStatus
    let captureDisplayColorSpace = acquiredCaptureContext.colorSpace
    let captureSource = acquiredCaptureContext.captureSource
    let allowsClientResize = acquiredCaptureContext.allowsClientResize
    let presentationResolution = acquiredCaptureContext.presentationResolution
    let virtualDisplaySnapshot = acquiredCaptureContext.virtualDisplaySnapshot
    let usesDisplayRefreshCadence = acquiredCaptureContext.usesDisplayRefreshCadence
    let acceptedDisplayScaleFactor = acquiredCaptureContext.acceptedDisplayScaleFactor ?? desktopBackingScale.scaleFactor
    desktopCaptureSource = captureSource

    applyMainDisplayFallbackProfileIfNeeded(captureSource: captureSource, config: &config)

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
    let transportPathKind = mediaPathPolicy.transportPathKind
    let mediaPathProfile = mediaPathPolicy.mediaPathProfile

    let streamContext = await makeDesktopStreamContext(
        DesktopStreamContextRequest(
            streamID: streamID,
            config: config,
            streamScale: computedStreamScale,
            audioConfiguration: resolvedAudioConfiguration,
            mediaMaxPacketSize: mediaMaxPacketSize,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
            allowEncoderCatchUpQualityAdjustment: allowEncoderCatchUpQualityAdjustment,
            disableResolutionCap: disableResolutionCap,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            hostBufferDepth: hostBufferDepth,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            mediaPathDiagnosticSummary: mediaPathPolicy.diagnosticSummary,
            enteredBitrate: enteredBitrate,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            compressionQualityCeiling: compressionQualityCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            cursorPresentation: cursorPresentation,
            desktopStartTime: desktopStartTime,
            captureDisplayP3CoverageStatus: captureDisplayP3CoverageStatus,
            virtualDisplaySnapshot: virtualDisplaySnapshot,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
    )
    MirageLogger.host(
        "event=media_path_policy phase=desktop_start stream=\(streamID) " +
            "\(mediaPathPolicy.diagnosticSummary) videoTransport=unreliableQueued " +
            "maxPacket=\(mediaMaxPacketSize)"
    )
    logDesktopStartStep("stream context created (\(streamID))")
    logDesktopStreamRuntimeOptions(
        streamID: streamID,
        allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment
    )
    await configureDesktopMetricsHandler(streamContext, clientContext: clientContext)

    try await ensureDesktopStreamSetupCanContinue(
        clientContext: clientContext,
        startupRequestID: startupRequestID,
        mode: mode,
        stage: "before stream activation"
    )

    let activationResult = try await activateAndStartDesktopStream(
        DesktopStreamActivation(
            streamID: streamID,
            clientContext: clientContext,
            streamContext: streamContext,
            requestedScaleFactor: acceptedDisplayScaleFactor,
            audioConfiguration: resolvedAudioConfiguration,
            mode: mode,
            startupRequestID: startupRequestID,
            captureDisplay: captureDisplay,
            captureResolution: captureResolution
        ),
        virtualDisplaySetupGuardToken: &virtualDisplaySetupGuardToken
    )
    logDesktopStartStep("display capture started")

    let startupAudioConfiguration: MirageAudioConfiguration
    do {
        startupAudioConfiguration = try await waitForDesktopCaptureStartupReadiness(
            streamContext: streamContext,
            mode: mode,
            clientID: activationResult.activeClientContext.client.id,
            audioConfiguration: activationResult.audioConfiguration
        )
        logDesktopStartStep("capture readiness satisfied")
    } catch {
        MirageLogger.error(
            .host,
            error: error,
            message: "Desktop display capture readiness failed after stream start; cleaning up stream state: "
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
    let acceptedDesktopGeometryRefreshTargetHz = MirageAwdlMediaController.fixedDisplayTargetFrameRate(
        requestedFrameRate: desktopGeometryRefreshTargetHz ?? effectiveDesktopTargetFrameRate,
        mediaPathProfile: mediaPathPolicy.mediaPathProfile
    )

    let startedDisplayResolution = try await sendDesktopStreamStartedNotification(
        DesktopStreamStartedNotification(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            activeClientContext: activationResult.activeClientContext,
            streamContext: streamContext,
            captureResolution: captureResolution,
            captureSource: captureSource,
            allowsClientResize: allowsClientResize,
            presentationResolution: presentationResolution,
            acceptedDisplayScaleFactor: acceptedDisplayScaleFactor,
            desktopGeometryContractID: desktopGeometryContractID,
            desktopGeometrySceneIdentity: desktopGeometrySceneIdentity,
            desktopGeometryRefreshTargetHz: acceptedDesktopGeometryRefreshTargetHz,
            presentationRole: presentationRole,
            associatedAppSessionID: associatedAppSessionID,
            associatedAppStartupRequestID: associatedAppStartupRequestID,
            associatedBundleIdentifier: associatedBundleIdentifier
        ),
        logDesktopStartStep: logDesktopStartStep
    )

    if startupAudioConfiguration.enabled != activationResult.audioConfiguration.enabled {
        MirageLogger.host(
            "Desktop start: startup audio configuration changed during capture readiness " +
                "(enabled=\(startupAudioConfiguration.enabled))"
        )
    }

    await finishDesktopStreamStartup(
        streamID: streamID,
        startedDisplayResolution: startedDisplayResolution,
        captureResolution: captureResolution
    )
    retainMediaPathClientEvidence = true
    clearDesktopStartupMarkerOnExit = false
}
}

#endif
