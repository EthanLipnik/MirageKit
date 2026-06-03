//
//  MirageHostService+Streams.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream lifecycle management.
//

import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
public extension MirageHostService {
    private struct StartedWindowStreamFinalizationRequest {
        let session: MirageStreamSession
        let context: StreamContext
        let updatedWindow: MirageWindow
        let streamID: StreamID
        let clientContext: ClientContext
    }

    /// Starts streaming a host window to a connected client.
    func startStream(
        for window: MirageWindow,
        to client: MirageConnectedClient,
        expectedSessionID: UUID? = nil,
        clientDisplayResolution: CGSize? = nil,
        clientScaleFactor: CGFloat? = nil,
        keyFrameInterval: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        hostBufferingPolicy: MirageHostBufferingPolicy = .freshestFrame,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool = false,
        disableResolutionCap: Bool = false,
        allowBestEffortRemap: Bool = true,
        audioConfiguration: MirageAudioConfiguration? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        mediaMaxPacketSize: Int = mirageDefaultMaxPacketSize,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil,
        sizePreset: MirageDisplaySizePreset = .standard
    )
    async throws {
        try await startStreamWithResolvedMediaPath(
            for: window,
            to: client,
            expectedSessionID: expectedSessionID,
            clientDisplayResolution: clientDisplayResolution,
            clientScaleFactor: clientScaleFactor,
            keyFrameInterval: keyFrameInterval,
            streamScale: streamScale,
            targetFrameRate: targetFrameRate,
            colorDepth: colorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCap,
            allowBestEffortRemap: allowBestEffortRemap,
            audioConfiguration: audioConfiguration,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            mediaMaxPacketSize: mediaMaxPacketSize,
            mediaPathPolicy: nil,
            upscalingMode: upscalingMode,
            codec: codec,
            sizePreset: sizePreset
        )
    }

    internal func startStreamWithResolvedMediaPath(
        for window: MirageWindow,
        to client: MirageConnectedClient,
        expectedSessionID: UUID? = nil,
        clientDisplayResolution: CGSize? = nil,
        clientScaleFactor: CGFloat? = nil,
        keyFrameInterval: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        hostBufferingPolicy: MirageHostBufferingPolicy = .freshestFrame,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool = false,
        disableResolutionCap: Bool = false,
        allowBestEffortRemap: Bool = true,
        audioConfiguration: MirageAudioConfiguration? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        mediaMaxPacketSize: Int = mirageDefaultMaxPacketSize,
        mediaPathPolicy: MirageEffectiveMediaPathPolicy? = nil,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil,
        sizePreset: MirageDisplaySizePreset = .standard
    )
    async throws {
        inputController.clearAllModifiers()

        guard !disconnectingClientIDs.contains(client.id),
              clientsByID[client.id] != nil else {
            throw MirageError.protocolError("Client is disconnected or disconnecting")
        }
        let startupClientContext = try startupClientContext(for: client, expectedSessionID: expectedSessionID)

        // Resolve capture sources from live ScreenCaptureKit content to avoid stale host window IDs.
        let content = try await SCShareableContent.mirageHostContent()
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys)
        let captureSource = try resolveCaptureSource(
            for: window,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: allowBestEffortRemap
        )
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let resolvedWindowID = WindowID(scWindow.windowID)
        if let existingStreamID = activeStreamIDByWindowID[resolvedWindowID] {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindowID,
                existingStreamID: existingStreamID
            )
        }
        if resolvedWindowID != window.id {
            MirageLogger.host("Resolved window \(window.id) to live window \(resolvedWindowID) for stream start")
        }

        guard let clientDisplayResolution,
              clientDisplayResolution.width > 0,
              clientDisplayResolution.height > 0 else {
            throw MirageError.protocolError("App/window streaming requires a client display resolution")
        }

        let streamID = nextStreamID
        nextStreamID += 1
        var retainMediaPathClientEvidence = false
        defer {
            if !retainMediaPathClientEvidence {
                mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
            }
        }

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let resolvedWindowFrame = scWindow.frame
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? resolvedWindowFrame
        let updatedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? window.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )

        let session = MirageStreamSession(
            id: streamID,
            window: updatedWindow,
            client: client
        )

        let effectiveEncoderConfig = resolveEncoderConfiguration(
            keyFrameInterval: keyFrameInterval,
            targetFrameRate: targetFrameRate,
            colorDepth: colorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate,
            upscalingMode: upscalingMode,
            codec: codec
        )
        guard mediaSecurityByClientID[client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for client")
        }

        guard !disconnectingClientIDs.contains(client.id),
              clientsByID[client.id] != nil else {
            throw MirageError.protocolError("Client is disconnected or disconnecting")
        }

        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline
        let resolvedAudioConfiguration = audioConfiguration ?? .default
        let resolvedMediaPathPolicy = mediaPathPolicy ?? effectiveMediaPathPolicy(
            clientContext: startupClientContext,
            clientPathKind: nil,
            clientMediaPathProfile: nil,
            clientPathSignature: nil
        )
        mediaPathClientEvidenceByStreamID[streamID] = HostStreamMediaPathClientEvidence(
            policy: resolvedMediaPathPolicy
        )
        let transportPathKind = resolvedMediaPathPolicy.transportPathKind
        let context = StreamContext(
            streamID: streamID,
            windowID: updatedWindow.id,
            streamKind: .window,
            encoderConfig: effectiveEncoderConfig,
            streamScale: streamScale ?? 1.0,
            requestedAudioChannelCount: resolvedAudioConfiguration.channelLayout.channelCount,
            maxPacketSize: mediaMaxPacketSize,
            mediaSecurityContext: nil,
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCap,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            transportPathKind: transportPathKind,
            mediaPathProfile: resolvedMediaPathPolicy.mediaPathProfile,
            mediaPathDiagnosticSummary: resolvedMediaPathPolicy.diagnosticSummary,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
        MirageLogger.host(
            "event=media_path_policy phase=window_start stream=\(streamID) " +
                "\(resolvedMediaPathPolicy.diagnosticSummary) " +
                "videoTransport=unreliableQueued maxPacket=\(mediaMaxPacketSize)"
        )
        logWindowStreamOptions(
            streamID: streamID,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            disableResolutionCap: disableResolutionCap,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: lowLatencyHighResolutionCompressionBoost
        )
        // Reserve stream/window ownership before the first await after binding resolution.
        // This closes a startup race where concurrent starts could otherwise bind the same
        // resolved live window before either stream reached registration.
        streamsByID[streamID] = context
        registerActiveStreamSession(session)
        await syncAppListRequestDeferralForInteractiveWorkload()
        let startupSessionID = startupClientContext.sessionID
        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.recordClientMediaActivity(clientID: client.id)
            self?.dispatchControlWork(clientID: client.id) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(sessionID: startupSessionID) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Stream metrics",
                        sessionID: startupSessionID
                    )
                }
            }
        }

        do {
            try await activateAudioForClient(
                clientID: client.id,
                expectedSessionID: startupSessionID,
                sourceStreamID: streamID,
                configuration: resolvedAudioConfiguration
            )
        } catch {
            await cleanupFailedStreamStart(
                streamID: streamID,
                context: context,
                windowID: updatedWindow.id
            )
            throw error
        }

        await PowerAssertionManager.shared.enable()

        inputStreamCache.set(streamID, window: updatedWindow, client: client)

        guard let clientContext = findClientContext(sessionID: startupSessionID) else {
            throw MirageError.protocolError("Client context missing for stream \(streamID)")
        }

        let videoStream: LoomMultiplexedStream
        do {
            let openedVideoStream = try await clientContext.controlChannel.session.openStream(
                label: "video/\(streamID)"
            )
            videoStream = openedVideoStream
            loomVideoStreamsByStreamID[streamID] = openedVideoStream
            transportRegistry.registerVideoStream(openedVideoStream, streamID: streamID)
            MirageLogger.host("Opened Loom video stream for stream \(streamID)")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to open Loom video stream for stream \(streamID): "
            )
            await cleanupFailedStreamStart(
                streamID: streamID,
                context: context,
                windowID: updatedWindow.id
            )
            throw error
        }

        let applicationWrapper = SCApplicationWrapper(application: scApplication)
        let displayWrapper = SCDisplayWrapper(display: captureSource.display)
        let mediaSendProfile = await clientContext.controlChannel.session.mirageMediaSendProfile(
            resolvedMediaPathProfile: resolvedMediaPathPolicy.mediaPathProfile,
            streamID: streamID,
            phase: "window_transport"
        )
        let mediaSendProfileReference = await context.setMediaSendProfile(
            mediaSendProfile,
            diagnosticsProvider: { profile in
                await videoStream.consumeQueuedUnreliableSendDiagnostics(profile: profile)
            }
        )
        MirageLogger.host(
            "event=media_path_policy phase=window_transport stream=\(streamID) " +
                "\(resolvedMediaPathPolicy.diagnosticSummary) " +
                "videoTransport=unreliableQueued sendProfile=\(mediaSendProfile.rawValue) " +
                "maxPacket=\(context.mediaMaxPacketSize)"
        )
        let sendPacketWithMetadata: StreamPacketSender.PacketMetadataSendHandler = { packetData, metadata, onComplete in
            let activeMediaSendProfile = mediaSendProfileReference.read { $0 }
            videoStream.sendUnreliableQueued(
                packetData,
                profile: activeMediaSendProfile,
                options: metadata.loomQueuedUnreliableSendOptions,
                onComplete: onComplete
            )
        }
        let onSendError: @Sendable (Error) -> Void = { [weak self] error in
            guard let self else { return }
            dispatchMainWork {
                await self.handleVideoSendError(streamID: streamID, error: error)
            }
        }

        do {
            let mirroredDisplaySnapshot = try await ensureSharedAppStreamMirroring(
                preset: sizePreset,
                refreshRate: effectiveEncoderConfig.targetFrameRate,
                colorSpace: effectiveEncoderConfig.colorSpace
            )
            try await context.startMirroredAppWindowCapture(
                applicationWrapper: applicationWrapper,
                displayWrapper: displayWrapper,
                mirroredDisplaySnapshot: mirroredDisplaySnapshot,
                sizePreset: sizePreset,
                clientLogicalSize: clientDisplayResolution,
                sendPacketWithMetadata: sendPacketWithMetadata,
                onSendError: onSendError
            )
            await refreshWindowVirtualDisplayState(
                streamID: streamID,
                context: context,
                clientScaleFactorOverride: clientScaleFactor,
                targetContentAspectRatioOverride: sizePreset.contentAspectRatio
            )
        } catch {
            await cleanupFailedStreamStart(
                streamID: streamID,
                context: context,
                windowID: updatedWindow.id
            )
            throw error
        }

        try await finalizeStartedWindowStream(
            StartedWindowStreamFinalizationRequest(
                session: session,
                context: context,
                updatedWindow: updatedWindow,
                streamID: streamID,
                clientContext: clientContext
            )
        )
        retainMediaPathClientEvidence = true
    }

    private func finalizeStartedWindowStream(
        _ request: StartedWindowStreamFinalizationRequest
    ) async throws {
        let updatedWindow = request.updatedWindow
        let resolvedStreamFrame = currentWindowFrame(for: updatedWindow.id) ?? updatedWindow.frame
        let resolvedWindow = MirageWindow(
            id: updatedWindow.id,
            title: updatedWindow.title,
            application: updatedWindow.application,
            frame: resolvedStreamFrame,
            isOnScreen: updatedWindow.isOnScreen,
            windowLayer: updatedWindow.windowLayer
        )
        let session = MirageStreamSession(
            id: request.session.id,
            window: resolvedWindow,
            client: request.session.client
        )
        registerActiveStreamSession(session)
        inputStreamCache.updateWindowFrame(request.streamID, newFrame: resolvedWindow.frame)
        activateWindow(resolvedWindow)

        try await sendWindowStreamStartedIfPossible(
            session,
            context: request.context,
            cleanupWindowID: updatedWindow.id
        )

        await markAppStreamInteraction(streamID: request.streamID, reason: "stream started")

        if let app = session.window.application {
            await startMenuBarMonitoring(streamID: request.streamID, app: app, clientContext: request.clientContext)
        }

        await updateLightsOutState()
        inputController.beginTrafficLightProtection(
            windowID: session.window.id,
            app: session.window.application,
            usesVirtualDisplay: isStreamUsingVirtualDisplay(windowID: session.window.id)
        )
        if isStreamUsingVirtualDisplay(windowID: session.window.id) {
            ensureWindowVisibleFrameMonitor(streamID: request.streamID)
        }
    }

    private func logWindowStreamOptions(
        streamID: StreamID,
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        disableResolutionCap: Bool,
        allowRuntimeQualityAdjustment: Bool?,
        lowLatencyHighResolutionCompressionBoost: Bool
    ) {
        if disableResolutionCap {
            MirageLogger.host("Resolution cap disabled for stream \(streamID)")
        }
        MirageLogger.host("Latency mode for stream \(streamID): \(latencyMode.displayName)")
        MirageLogger.host("Host buffering policy for stream \(streamID): \(hostBufferingPolicy.rawValue)")
        if allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for stream \(streamID)")
        }
        if !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for stream \(streamID)")
        }
    }

    private func sendWindowStreamStartedIfPossible(
        _ session: MirageStreamSession,
        context: StreamContext,
        cleanupWindowID: WindowID
    ) async throws {
        let streamID = session.id
        guard let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) else {
            return
        }

        let streamWindow = session.window
        let minSize = await resolvedMinimumSize(for: streamWindow)
        let streamStart = await context.streamStartSnapshot
        let startupAttemptID = UUID()
        let message = StreamStartedMessage(
            streamID: streamID,
            windowID: streamWindow.id,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            startupAttemptID: startupAttemptID,
            minWidth: Int(minSize.width),
            minHeight: Int(minSize.height),
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
        )

        do {
            registerPendingStartupAttempt(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                sessionID: clientContext.sessionID,
                clientID: clientContext.client.id,
                kind: .window
            )
            try await clientContext.send(.streamStarted, content: message)
            MirageLogger.signpostEvent(.host, "Startup.StreamStartedSent", "stream=\(streamID) kind=window")
        } catch {
            cancelPendingStartupAttempt(streamID: streamID)
            await cleanupFailedStreamStart(
                streamID: streamID,
                context: context,
                windowID: cleanupWindowID
            )
            throw error
        }
    }

}
#endif
