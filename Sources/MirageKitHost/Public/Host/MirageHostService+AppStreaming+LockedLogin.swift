//
//  MirageHostService+AppStreaming+LockedLogin.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//
//  Locked-session app stream login handling.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    func acceptLockedAppStreamIntent(
        request: MirageWire.SelectAppMessage,
        clientContext: ClientContext,
        targetFrameRate: Int,
        mediaPathPolicy: MirageEffectiveMediaPathPolicy,
        mediaMaxPacketSize: Int
    ) async throws {
        let appSessionID = request.appSessionID
        let supersededAppSessionIDs = pendingLockedAppStreamIntentsByAppSessionID
            .filter { key, intent in
                key != appSessionID &&
                    intent.clientID == clientContext.client.id
            }
            .map(\.key)
        for supersededAppSessionID in supersededAppSessionIDs {
            if let superseded = removePendingLockedAppStreamIntent(appSessionID: supersededAppSessionID) {
                await stopLockedAppLoginStream(for: superseded, notifyClient: true)
            }
        }

        let existingLoginStreamID = pendingLockedAppStreamIntentsByAppSessionID[appSessionID]?.loginStreamID
        if pendingLockedAppStreamIntentsByAppSessionID[appSessionID] == nil {
            pendingLockedAppStreamIntentOrder.append(appSessionID)
        }
        var intent = PendingLockedAppStreamIntent(
            request: request,
            clientSessionID: clientContext.sessionID,
            clientID: clientContext.client.id,
            createdAt: Date(),
            loginStreamID: existingLoginStreamID,
            isResuming: false
        )
        pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = intent

        if intent.loginStreamID != nil {
            try await sendLockedAppLoginStreamAnnouncements(
                intent: intent,
                clientContext: clientContext
            )
            MirageLogger.host(
                "Accepted locked app stream \(request.bundleIdentifier); reusing app-stream login stream \(intent.loginStreamID.map(String.init) ?? "nil")"
            )
            return
        }

        do {
            let loginStreamID = try await startLockedAppLoginStream(
                request: request,
                clientContext: clientContext,
                targetFrameRate: targetFrameRate,
                mediaPathPolicy: mediaPathPolicy,
                mediaMaxPacketSize: mediaMaxPacketSize
            )
            intent.loginStreamID = loginStreamID
            pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = intent
            MirageLogger.host(
                "Accepted locked app stream \(request.bundleIdentifier); started app-stream login stream \(loginStreamID)"
            )
        } catch {
            _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
            await restoreStageManagerAfterAppStreamingIfNeeded()
            throw error
        }
    }

    private func startLockedAppLoginStream(
        request: MirageWire.SelectAppMessage,
        clientContext: ClientContext,
        targetFrameRate: Int,
        mediaPathPolicy: MirageEffectiveMediaPathPolicy,
        mediaMaxPacketSize: Int
    ) async throws -> StreamID {
        let clientID = clientContext.client.id
        guard mediaSecurityByClientID[clientID] != nil else {
            throw MirageCore.MirageError.protocolError("Missing media security context for client")
        }

        let preset = request.sizePreset ?? .standard
        let loginCaptureDisplayID = CGMainDisplayID()
        let displaySnapshot = try await ensureSharedAppStreamMirroring(
            preset: preset,
            refreshRate: targetFrameRate,
            colorSpace: request.colorDepth?.colorSpace ?? encoderConfig.colorSpace,
            mirrorPhysicalDisplays: false
        )

        let streamID = nextStreamID
        nextStreamID += 1
        var context: StreamContext?
        do {
            let displayWrapper = try await lockedAppLoginCaptureDisplay(
                displayID: loginCaptureDisplayID,
                fallbackDisplayID: displaySnapshot.displayID
            )
            var loginEncoderConfig = resolveEncoderConfiguration(
                keyFrameInterval: request.keyFrameInterval,
                targetFrameRate: targetFrameRate,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                bitrate: request.bitrate,
                upscalingMode: nil,
                codec: request.codec
            )
            loginEncoderConfig.targetFrameRate = targetFrameRate

            let latencyMode = request.latencyMode ?? .lowestLatency
            let hostBufferingPolicy = request.resolvedHostBufferingPolicy
            let audioConfiguration = request.audioConfiguration ?? audioConfigurationByClientID[clientID] ?? .default
            mediaPathClientEvidenceByStreamID[streamID] = HostStreamMediaPathClientEvidence(
                policy: mediaPathPolicy
            )
            let loginContext = StreamContext(
                streamID: streamID,
                windowID: 0,
                streamKind: .appAtlas,
                encoderConfig: loginEncoderConfig,
                streamScale: 1.0,
                requestedAudioChannelCount: audioConfiguration.channelLayout.channelCount,
                maxPacketSize: mediaMaxPacketSize,
                mediaSecurityContext: nil,
                runtimeQualityAdjustmentEnabled: request.allowRuntimeQualityAdjustment ?? true,
                encoderCatchUpQualityAdjustmentEnabled: request.allowEncoderCatchUpQualityAdjustment ?? true,
                lowLatencyHighResolutionCompressionBoostEnabled: request.lowLatencyHighResolutionCompressionBoost ?? false,
                disableResolutionCap: true,
                encoderLowPowerEnabled: isEncoderLowPowerModeActive,
                capturePressureProfile: .baseline,
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                transportPathKind: mediaPathPolicy.transportPathKind,
                mediaPathProfile: mediaPathPolicy.mediaPathProfile,
                mediaPathDiagnosticSummary: mediaPathPolicy.diagnosticSummary,
                enteredBitrate: request.enteredBitrate,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                captureShowsCursor: false,
                videoEncoderFactoryBackend: platformVideoEncoderFactoryBackend,
                captureEngineFactoryBackend: platformCaptureEngineFactoryBackend,
                captureContentProviderBackend: platformCaptureContentProviderBackend,
                virtualDisplayBackend: platformVirtualDisplayBackend
            )
            context = loginContext
            streamsByID[streamID] = loginContext
            MirageLogger.host(
                "event=media_path_policy phase=locked_app_login_start stream=\(streamID) " +
                    "\(mediaPathPolicy.diagnosticSummary) videoTransport=unreliableQueued " +
                    "maxPacket=\(mediaMaxPacketSize)"
            )

            await loginContext.setMetricsUpdateHandler { [weak self] metrics in
                self?.recordClientMediaActivity(clientID: clientID)
                self?.dispatchControlWork(clientID: clientID) { [weak self] in
                    guard let self else { return }
                    guard let currentClientContext = findClientContext(sessionID: clientContext.sessionID) else { return }
                    do {
                        try await currentClientContext.send(.streamMetricsUpdate, content: metrics)
                    } catch {
                        await handleControlChannelSendFailure(
                            client: currentClientContext.client,
                            error: error,
                            operation: "Locked app login stream metrics",
                            sessionID: clientContext.sessionID
                        )
                    }
                }
            }

            try await activateAudioForClient(
                clientID: clientID,
                expectedSessionID: clientContext.sessionID,
                sourceStreamID: streamID,
                configuration: audioConfiguration
            )
            await PowerAssertionManager.shared.enable()

            let videoStream = try await clientContext.controlChannel.session.openStream(
                label: "video/\(streamID)"
            )
            videoMediaStreamsByStreamID[streamID] = videoStream
            transportRegistry.registerVideoStream(videoStream, streamID: streamID)
            MirageLogger.host("Opened Loom locked-app login video stream \(streamID)")

            let mediaSendProfile = await clientContext.controlChannel.session.mirageMediaSendProfile(
                resolvedMediaPathProfile: mediaPathPolicy.mediaPathProfile,
                streamID: streamID,
                phase: "locked_app_login_transport",
                logHostEvent: { message in MirageLogger.host(message) }
            )
            let mediaSendProfileReference = await loginContext.setMediaSendProfile(
                mediaSendProfile,
                diagnosticsProvider: { profile in
                    await videoStream.mirageQueuedUnreliableSendDiagnostics(profile: profile)
                }
            )
            MirageLogger.host(
                "event=media_path_policy phase=locked_app_login_transport stream=\(streamID) " +
                    "\(mediaPathPolicy.diagnosticSummary) videoTransport=unreliableQueued " +
                    "sendProfile=\(mediaSendProfile.rawValue) maxPacket=\(loginContext.mediaMaxPacketSize)"
            )
            MirageLogger.host(
                "Locked app login stream \(streamID) capturing display \(displayWrapper.display.displayID) " +
                    "into app-stream geometry \(Int(displaySnapshot.resolution.width))x\(Int(displaySnapshot.resolution.height))"
            )

            try await loginContext.startAppStreamDisplayCapture(
                displayWrapper: displayWrapper,
                mirroredDisplaySnapshot: displaySnapshot,
                sendPacketWithMetadata: { packetData, metadata, onComplete in
                    let activeMediaSendProfile = mediaSendProfileReference.read { $0 }
                    videoStream.sendUnreliableQueued(
                        packetData,
                        profile: activeMediaSendProfile,
                        options: metadata.mirageQueuedUnreliableSendOptions,
                        onComplete: onComplete
                    )
                },
                onSendError: { [weak self] error in
                    guard let self else { return }
                    dispatchMainWork {
                        await self.handleVideoSendError(streamID: streamID, error: error)
                    }
                }
            )

            let loginWindow = lockedAppLoginWindow(request: request)
            registerActiveStreamSession(
                MirageStreamSession(
                    id: streamID,
                    window: loginWindow,
                    client: clientContext.client
                )
            )
            inputStreamCache.set(streamID, window: loginWindow, client: clientContext.client)
            await syncAppListRequestDeferralForInteractiveWorkload()
            await updateLightsOutState()
            pendingLockedAppStreamIntentsByAppSessionID[request.appSessionID]?.loginStreamID = streamID

            try await sendLockedAppLoginStreamAnnouncements(
                request: request,
                streamID: streamID,
                context: loginContext,
                clientContext: clientContext
            )
            await loginContext.allowEncodingAfterRegistration()
            return streamID
        } catch {
            if let context {
                await cleanupFailedStreamStart(streamID: streamID, context: context, windowID: 0)
            } else {
                mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
                await teardownSharedAppStreamMirroringIfIdle(displayID: displaySnapshot.displayID)
            }
            throw error
        }
    }

    private func lockedAppLoginCaptureDisplay(
        displayID: CGDirectDisplayID,
        fallbackDisplayID: CGDirectDisplayID
    ) async throws -> SCDisplayWrapper {
        do {
            let captureDisplay = try await platformVirtualDisplayBackend.findCaptureDisplay(
                displayID: displayID,
                maxAttempts: 12,
                startupBudget: nil
            )
            return try await resolveSCDisplayWrapper(
                for: captureDisplay,
                label: "locked app login console display"
            )
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to resolve console display \(displayID) for locked app login stream; falling back to shared app display: "
            )
            let fallbackDisplay = try await platformVirtualDisplayBackend.findCaptureDisplay(
                displayID: fallbackDisplayID,
                maxAttempts: 12,
                startupBudget: nil
            )
            return try await resolveSCDisplayWrapper(
                for: fallbackDisplay,
                label: "locked app login shared app fallback display"
            )
        }
    }

    private func sendLockedAppLoginStreamAnnouncements(
        intent: PendingLockedAppStreamIntent,
        clientContext: ClientContext
    ) async throws {
        guard let streamID = intent.loginStreamID,
              let context = streamsByID[streamID] else {
            throw MirageCore.MirageError.protocolError("Missing locked app login stream")
        }
        try await sendLockedAppLoginStreamAnnouncements(
            request: intent.request,
            streamID: streamID,
            context: context,
            clientContext: clientContext
        )
    }

    private func sendLockedAppLoginStreamAnnouncements(
        request: MirageWire.SelectAppMessage,
        streamID: StreamID,
        context: StreamContext,
        clientContext: ClientContext
    ) async throws {
        let streamStart = await context.streamStartSnapshot
        let layout = lockedAppLoginLayout(
            streamID: streamID,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height
        )
        let mediaUpdate = MirageWire.AppAtlasMediaUpdateMessage(
            mediaStreamID: streamID,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            codec: streamStart.codec,
            frameRate: streamStart.targetFrameRate,
            dimensionToken: streamStart.dimensionToken,
            layoutEpoch: layout.layoutEpoch,
            acceptedPacketSize: streamStart.mediaMaxPacketSize,
            layout: layout,
            startupAttemptID: request.startupRequestID
        )
        try await clientContext.send(.appAtlasMediaUpdate, content: mediaUpdate)
        let started = MirageWire.AppStreamStartedMessage(
            appSessionID: request.appSessionID,
            startupRequestID: request.startupRequestID,
            bundleIdentifier: request.bundleIdentifier,
            appName: lockedAppLoginAppName(for: request),
            windows: [
                MirageWire.AppStreamStartedMessage.AppStreamWindow(
                    streamID: streamID,
                    mediaStreamID: streamID,
                    windowID: 0,
                    title: "Sign In",
                    width: Int((request.sizePreset ?? .standard).logicalResolution.width.rounded()),
                    height: Int((request.sizePreset ?? .standard).logicalResolution.height.rounded()),
                    isResizable: false,
                    atlasRegion: layout.regions.first
                )
            ],
            atlasLayouts: [layout]
        )
        try await clientContext.send(.appStreamStarted, content: started)
    }

    private func lockedAppLoginLayout(
        streamID: StreamID,
        width: Int,
        height: Int
    ) -> MirageMedia.MirageAppAtlasLayout {
        let encodedWidth = max(1, width)
        let encodedHeight = max(1, height)
        return MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: streamID,
            layoutEpoch: 1,
            width: encodedWidth,
            height: encodedHeight,
            regions: [
                MirageMedia.MirageAppAtlasRegion(
                    windowID: 0,
                    x: 0,
                    y: 0,
                    width: encodedWidth,
                    height: encodedHeight,
                    isFocused: true,
                    isVisible: true
                )
            ]
        )
    }

    private func lockedAppLoginWindow(request: MirageWire.SelectAppMessage) -> MirageMedia.MirageWindow {
        let logicalResolution = (request.sizePreset ?? .standard).logicalResolution
        return MirageMedia.MirageWindow(
            id: 0,
            title: "Sign In",
            application: MirageMedia.MirageApplication(
                id: 0,
                bundleIdentifier: request.bundleIdentifier,
                name: lockedAppLoginAppName(for: request)
            ),
            frame: CGRect(
                x: 0,
                y: 0,
                width: logicalResolution.width,
                height: logicalResolution.height
            ),
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private func lockedAppLoginAppName(for request: MirageWire.SelectAppMessage) -> String {
        request.bundleIdentifier
            .split(separator: ".")
            .last
            .map(String.init) ?? request.bundleIdentifier
    }

    func stopLockedAppLoginStream(
        for intent: PendingLockedAppStreamIntent,
        notifyClient: Bool
    ) async {
        guard let streamID = intent.loginStreamID else { return }
        if let session = activeSessionByStreamID[streamID] {
            await stopStream(
                session,
                minimizeWindow: false,
                updateAppSession: false,
                triggeredByExplicitStreamStop: false
            )
        } else if let context = streamsByID[streamID] {
            await cleanupFailedStreamStart(streamID: streamID, context: context, windowID: 0)
        } else {
            inputStreamCache.remove(streamID)
            if let videoStream = videoMediaStreamsByStreamID.removeValue(forKey: streamID) {
                closeRemovedMediaStream(videoStream, streamID: streamID, kind: "video")
            }
            transportRegistry.unregisterVideoStream(streamID: streamID)
        }

        guard notifyClient,
              let clientContext = findClientContext(sessionID: intent.clientSessionID) else {
            return
        }
        let removed = MirageWire.WindowRemovedFromStreamMessage(
            bundleIdentifier: intent.request.bundleIdentifier,
            appSessionID: intent.request.appSessionID,
            streamID: streamID,
            windowID: 0,
            reason: .noLongerEligible
        )
        do {
            try await clientContext.send(.windowRemovedFromStream, content: removed)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to remove locked app login stream: ")
        }
    }

    func handleLockedAppLoginDisplayResolutionChange(
        streamID: StreamID,
        requestedSize: CGSize
    ) async -> Bool {
        guard let intent = pendingLockedAppStreamIntentsByAppSessionID.values.first(where: {
            $0.loginStreamID == streamID
        }) else {
            return false
        }
        guard let clientContext = findClientContext(sessionID: intent.clientSessionID),
              let session = activeSessionByStreamID[streamID] else {
            return true
        }

        let observedSize = session.window.frame.size
        let result = MirageWire.AppWindowResizeResultMessage(
            streamID: streamID,
            mediaStreamID: streamID,
            windowID: session.window.id,
            outcome: .noChange,
            requestedWidth: Int(max(1, requestedSize.width.rounded())),
            requestedHeight: Int(max(1, requestedSize.height.rounded())),
            observedWidth: Int(max(1, observedSize.width.rounded())),
            observedHeight: Int(max(1, observedSize.height.rounded())),
            minWidth: nil,
            minHeight: nil,
            reason: "lockedLoginFixedSurface"
        )
        do {
            try await clientContext.send(.appWindowResizeResult, content: result)
            MirageLogger.host(
                "Ignored display resolution change for locked app login stream \(streamID): " +
                    "\(Int(requestedSize.width))x\(Int(requestedSize.height)) pts"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send locked app login resize result: ")
        }
        return true
    }

    func removePendingLockedAppStreamIntent(
        appSessionID: UUID
    ) -> PendingLockedAppStreamIntent? {
        let removed = pendingLockedAppStreamIntentsByAppSessionID.removeValue(forKey: appSessionID)
        pendingLockedAppStreamIntentOrder.removeAll { $0 == appSessionID }
        return removed
    }

    func removePendingLockedAppStreamIntents(clientID: UUID) {
        let appSessionIDs = pendingLockedAppStreamIntentsByAppSessionID
            .filter { $0.value.clientID == clientID }
            .map(\.key)
        for appSessionID in appSessionIDs {
            _ = removePendingLockedAppStreamIntent(appSessionID: appSessionID)
        }
    }

    func resumePendingLockedAppStreamIntentsIfNeeded() async {
        guard mirageSessionAvailability == .ready else { return }
        let orderedIDs = pendingLockedAppStreamIntentOrder
        for appSessionID in orderedIDs {
            guard var intent = pendingLockedAppStreamIntentsByAppSessionID[appSessionID],
                  !intent.isResuming else {
                continue
            }
            guard let clientContext = findClientContext(sessionID: intent.clientSessionID),
                  clientContext.client.id == intent.clientID,
                  !disconnectingClientIDs.contains(intent.clientID) else {
                if let removed = removePendingLockedAppStreamIntent(appSessionID: appSessionID) {
                    await stopLockedAppLoginStream(for: removed, notifyClient: false)
                    await restoreStageManagerAfterAppStreamingIfNeeded()
                }
                continue
            }
            intent.isResuming = true
            pendingLockedAppStreamIntentsByAppSessionID[appSessionID] = intent
            do {
                let message = try MirageWire.ControlMessage(type: .selectApp, content: intent.request)
                await handleSelectApp(message, from: clientContext)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to resume locked app stream intent: ")
                sendAppSelectionError(
                    to: clientContext,
                    code: .appStreamStartupFailed,
                    message: Self.appStreamStartupFailureMessage(appName: intent.request.bundleIdentifier),
                    bundleIdentifier: intent.request.bundleIdentifier
                )
            }
            if let completedIntent = removePendingLockedAppStreamIntent(appSessionID: appSessionID) {
                await stopLockedAppLoginStream(for: completedIntent, notifyClient: true)
                await restoreStageManagerAfterAppStreamingIfNeeded()
            }
        }
    }
}
#endif
