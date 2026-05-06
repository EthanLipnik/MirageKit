//
//  MirageHostService+AppAtlas.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreGraphics
import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    struct AppAtlasStartedWindow: Sendable {
        let session: MirageStreamSession
        let attachment: AppAtlasWindowAttachment
    }

    func startAppAtlasWindowCapture(
        app: MirageInstalledApp,
        window: MirageWindow,
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedBitrate: Int?,
        mediaMaxPacketSize: Int,
        isResizable: Bool
    ) async throws -> AppAtlasStartedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys)
        let captureSource = try resolveCaptureSource(
            for: window,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: true
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

        let logicalStreamID = nextStreamID
        nextStreamID += 1

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? scWindow.frame
        let resolvedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? window.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )

        let coordinator = try await ensureAppAtlasCoordinator(
            clientContext: clientContext,
            selectRequest: selectRequest,
            targetFrameRate: targetFrameRate,
            requestedBitrate: requestedBitrate,
            mediaMaxPacketSize: mediaMaxPacketSize
        )
        let attachment = try await coordinator.addWindow(
            streamID: logicalStreamID,
            window: resolvedWindow,
            windowWrapper: SCWindowWrapper(window: scWindow),
            applicationWrapper: SCApplicationWrapper(application: scApplication),
            displayWrapper: SCDisplayWrapper(display: captureSource.display),
            isResizable: isResizable
        )

        let session = MirageStreamSession(
            id: logicalStreamID,
            window: resolvedWindow,
            client: clientContext.client
        )
        registerActiveStreamSession(session)
        inputStreamCacheActor.set(logicalStreamID, window: resolvedWindow, client: clientContext.client)
        activateWindow(resolvedWindow)

        if let app = resolvedWindow.application {
            await startMenuBarMonitoring(streamID: logicalStreamID, app: app, clientContext: clientContext)
        }
        inputController.beginTrafficLightProtection(
            windowID: resolvedWindow.id,
            app: resolvedWindow.application,
            usesVirtualDisplay: false
        )
        await markAppStreamInteraction(streamID: logicalStreamID, reason: "app atlas window started")
        await syncAppListRequestDeferralForInteractiveWorkload()
        await updateLightsOutState()

        MirageLogger.host(
            "Started app-atlas logical window \(resolvedWindow.id) stream=\(logicalStreamID) media=\(attachment.mediaStreamID) app=\(app.bundleIdentifier)"
        )
        return AppAtlasStartedWindow(session: session, attachment: attachment)
    }

    func replaceAppAtlasWindowCapture(
        streamSession: MirageStreamSession,
        currentWindowID: WindowID,
        targetWindowID: WindowID,
        hiddenInfo: AppStreamHiddenWindowInfo,
        clientContext: ClientContext
    ) async throws -> AppAtlasStartedWindow {
        guard let coordinator = appAtlasCoordinatorsByClientID[clientContext.client.id] else {
            throw MirageError.protocolError("App-atlas coordinator is unavailable")
        }

        let requestedWindow = MirageWindow(
            id: targetWindowID,
            title: hiddenInfo.title,
            application: streamSession.window.application,
            frame: currentWindowFrame(for: targetWindowID) ?? CGRect(
                x: streamSession.window.frame.origin.x,
                y: streamSession.window.frame.origin.y,
                width: CGFloat(max(1, hiddenInfo.width)),
                height: CGFloat(max(1, hiddenInfo.height))
            ),
            isOnScreen: true,
            windowLayer: 0
        )
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys).subtracting([currentWindowID])
        let captureSource = try resolveCaptureSource(
            for: requestedWindow,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: false
        )
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let resolvedWindowID = WindowID(scWindow.windowID)
        guard resolvedWindowID == targetWindowID else {
            throw MirageError.windowNotFound
        }
        if let existingStreamID = activeStreamIDByWindowID[resolvedWindowID],
           existingStreamID != streamSession.id {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindowID,
                existingStreamID: existingStreamID
            )
        }

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? scWindow.frame
        let resolvedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? hiddenInfo.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )
        let processID = resolvedWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(
                    processID: processID
        )
        let attachment = try await coordinator.replaceWindow(
            streamID: streamSession.id,
            window: resolvedWindow,
            windowWrapper: SCWindowWrapper(window: scWindow),
            applicationWrapper: SCApplicationWrapper(application: scApplication),
            displayWrapper: SCDisplayWrapper(display: captureSource.display),
            isResizable: isResizable
        )

        inputController.endTrafficLightProtection(windowID: currentWindowID)
        registerActiveStreamSession(
            MirageStreamSession(
                id: streamSession.id,
                window: resolvedWindow,
                client: streamSession.client
            )
        )
        inputStreamCacheActor.set(streamSession.id, window: resolvedWindow, client: streamSession.client)
        activateWindow(resolvedWindow)

        if let app = resolvedWindow.application {
            await startMenuBarMonitoring(streamID: streamSession.id, app: app, clientContext: clientContext)
        }
        inputController.beginTrafficLightProtection(
            windowID: resolvedWindow.id,
            app: resolvedWindow.application,
            usesVirtualDisplay: false
        )
        await markAppStreamInteraction(streamID: streamSession.id, reason: "app atlas window replaced")
        await syncAppListRequestDeferralForInteractiveWorkload()
        await updateLightsOutState()

        MirageLogger.host(
            "Replaced app-atlas logical stream \(streamSession.id) window \(currentWindowID) -> \(resolvedWindowID) " +
                "media=\(attachment.mediaStreamID)"
        )
        let updatedSession = MirageStreamSession(
            id: streamSession.id,
            window: resolvedWindow,
            client: streamSession.client
        )
        return AppAtlasStartedWindow(session: updatedSession, attachment: attachment)
    }

    func stopAppAtlasWindow(streamID: StreamID, clientID: UUID) async {
        guard let coordinator = appAtlasCoordinatorsByClientID[clientID] else { return }
        await coordinator.removeWindow(streamID: streamID)
        if await coordinator.isEmpty {
            await stopAppAtlasCoordinator(clientID: clientID)
        }
    }

    func stopAppAtlasCoordinator(clientID: UUID, stopLogicalSessions: Bool = false) async {
        if stopLogicalSessions, let coordinator = appAtlasCoordinatorsByClientID[clientID] {
            let logicalStreamIDs = await coordinator.logicalStreamIDs()
            let logicalSessions = appAtlasLogicalSessions(clientID: clientID, streamIDs: logicalStreamIDs)
            let activeLogicalStreamIDs = Set(logicalSessions.map(\.id))
            for session in logicalSessions {
                await stopStream(
                    session,
                    minimizeWindow: false,
                    updateAppSession: true,
                    triggeredByExplicitStreamStop: false
                )
            }
            for streamID in logicalStreamIDs where !activeLogicalStreamIDs.contains(streamID) {
                if appAtlasCoordinatorsByClientID[clientID] != nil {
                    await coordinator.removeWindow(streamID: streamID)
                }
            }
        }

        guard let coordinator = appAtlasCoordinatorsByClientID.removeValue(forKey: clientID) else { return }
        let mediaStreamID = coordinator.mediaStreamID
        cancelPendingStartupAttempt(streamID: mediaStreamID)
        await coordinator.stop()
        streamsByID.removeValue(forKey: mediaStreamID)
        unregisterStallWindowPointerRoute(streamID: mediaStreamID)
        await deactivateAudioSourceIfNeeded(streamID: mediaStreamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: mediaStreamID) {
            Task { try? await videoStream.close() }
        }
        transportRegistry.unregisterVideoStream(streamID: mediaStreamID)
        await teardownSharedAppStreamMirroringIfIdle(displayID: nil)
        MirageLogger.host("Stopped app-atlas media stream \(mediaStreamID) for client \(clientID.uuidString)")
    }

    func appAtlasLogicalSessions(clientID: UUID, streamIDs: [StreamID]) -> [MirageStreamSession] {
        let streamIDSet = Set(streamIDs)
        return activeStreams.filter { session in
            session.client.id == clientID && streamIDSet.contains(session.id)
        }
    }

    private func ensureAppAtlasCoordinator(
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedBitrate: Int?,
        mediaMaxPacketSize: Int
    ) async throws -> AppAtlasMediaCoordinator {
        let clientID = clientContext.client.id
        if let existing = appAtlasCoordinatorsByClientID[clientID] {
            return existing
        }

        if appAtlasCoordinatorCreationClientIDs.contains(clientID) {
            MirageLogger.host(
                "Waiting for in-flight app-atlas coordinator setup for client \(clientID.uuidString)"
            )
            while appAtlasCoordinatorCreationClientIDs.contains(clientID) {
                try? await Task.sleep(for: .milliseconds(20))
                if let existing = appAtlasCoordinatorsByClientID[clientID] {
                    return existing
                }
            }
            if let existing = appAtlasCoordinatorsByClientID[clientID] {
                return existing
            }
        }

        appAtlasCoordinatorCreationClientIDs.insert(clientID)
        defer {
            appAtlasCoordinatorCreationClientIDs.remove(clientID)
        }

        if let existing = appAtlasCoordinatorsByClientID[clientID] {
            return existing
        }

        guard mediaSecurityByClientID[clientID] != nil else {
            throw MirageError.protocolError("Missing media security context for client")
        }

        do {
            _ = try await ensureSharedAppStreamMirroring(
                preset: selectRequest.sizePreset ?? .standard,
                refreshRate: targetFrameRate,
                colorSpace: selectRequest.colorDepth?.colorSpace ?? encoderConfig.colorSpace
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "App-atlas shared display backing unavailable; continuing with direct capture: ")
        }

        let mediaStreamID = nextStreamID
        nextStreamID += 1

        var atlasEncoderConfig = resolveEncoderConfiguration(
            keyFrameInterval: selectRequest.keyFrameInterval,
            targetFrameRate: targetFrameRate,
            colorDepth: selectRequest.colorDepth,
            captureQueueDepth: selectRequest.captureQueueDepth,
            bitrate: requestedBitrate ?? selectRequest.bitrate,
            upscalingMode: nil,
            codec: selectRequest.codec
        )
        atlasEncoderConfig = atlasEncoderConfig.withInternalOverrides(pixelFormat: .bgra8)

        let latencyMode = selectRequest.latencyMode ?? .lowestLatency
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline
        let audioConfiguration = selectRequest.audioConfiguration ?? audioConfigurationByClientID[clientID] ?? .default
        let context = StreamContext(
            streamID: mediaStreamID,
            windowID: 0,
            streamKind: .appAtlas,
            encoderConfig: atlasEncoderConfig,
            streamScale: 1.0,
            requestedAudioChannelCount: audioConfiguration.channelLayout.channelCount,
            maxPacketSize: mediaMaxPacketSize,
            mediaSecurityContext: nil,
            runtimeQualityAdjustmentEnabled: selectRequest.allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: selectRequest.lowLatencyHighResolutionCompressionBoost ?? false,
            disableResolutionCap: true,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            bitrateAdaptationCeiling: selectRequest.bitrateAdaptationCeiling,
            encoderMaxWidth: selectRequest.encoderMaxWidth,
            encoderMaxHeight: selectRequest.encoderMaxHeight
        )
        streamsByID[mediaStreamID] = context

        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.recordClientMediaActivity(clientID: clientContext.client.id)
            self?.dispatchControlWork(clientID: clientContext.client.id) { [weak self] in
                guard let self else { return }
                guard let currentClientContext = findClientContext(sessionID: clientContext.sessionID) else { return }
                do {
                    try await currentClientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: currentClientContext.client,
                        error: error,
                        operation: "App atlas stream metrics",
                        sessionID: clientContext.sessionID
                    )
                }
            }
        }

        do {
            try await activateAudioForClient(
                clientID: clientID,
                expectedSessionID: clientContext.sessionID,
                sourceStreamID: mediaStreamID,
                configuration: audioConfiguration
            )
            await PowerAssertionManager.shared.enable()
        } catch {
            streamsByID.removeValue(forKey: mediaStreamID)
            throw error
        }

        let videoStream: LoomMultiplexedStream
        do {
            let openedVideoStream = try await clientContext.controlChannel.session.openStream(
                label: "video/\(mediaStreamID)"
            )
            videoStream = openedVideoStream
            loomVideoStreamsByStreamID[mediaStreamID] = openedVideoStream
            transportRegistry.registerVideoStream(openedVideoStream, streamID: mediaStreamID)
            MirageLogger.host("Opened Loom app-atlas video stream \(mediaStreamID)")
        } catch {
            streamsByID.removeValue(forKey: mediaStreamID)
            await deactivateAudioSourceIfNeeded(streamID: mediaStreamID)
            throw error
        }

        let coordinator = AppAtlasMediaCoordinator(
            clientID: clientID,
            mediaStreamID: mediaStreamID,
            context: context,
            encoderConfig: atlasEncoderConfig,
            latencyMode: latencyMode,
            capturePressureProfile: capturePressureProfile,
            targetFrameRate: targetFrameRate,
            sendPacket: { packetData, onComplete in
                videoStream.sendUnreliableQueued(packetData, onComplete: onComplete)
            },
            onSendError: { [weak self] error in
                guard let self else { return }
                dispatchMainWork {
                    await self.handleVideoSendError(streamID: mediaStreamID, error: error)
                }
            },
            sendMediaUpdate: { [weak self] update in
                guard let self else { return }
                do {
                    try await clientContext.send(.appAtlasMediaUpdate, content: update)
                } catch {
                    await self.handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "App atlas media update",
                        sessionID: clientContext.sessionID
                    )
                }
            }
        )
        appAtlasCoordinatorsByClientID[clientContext.client.id] = coordinator
        return coordinator
    }
}
#endif
