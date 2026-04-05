//
//  MirageHostService+MessageHandling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message routing.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func sendControlError(
        _ code: ErrorMessage.ErrorCode,
        message: String,
        streamID: StreamID? = nil,
        to clientContext: ClientContext
    ) {
        let payload = ErrorMessage(code: code, message: message, streamID: streamID)
        guard let response = try? ControlMessage(type: .error, content: payload) else {
            MirageLogger.error(.host, "Failed to encode error response: \(message)")
            return
        }
        clientContext.sendBestEffort(response)
    }

    func registerControlMessageHandlers() {
        controlMessageHandlers = [
            .startStream: { [weak self] message, clientContext in
                await self?.handleStartStreamMessage(message, from: clientContext)
            },
            .displayResolutionChange: { [weak self] message, _ in
                await self?.handleDisplayResolutionChangeMessage(message)
            },
            .streamScaleChange: { [weak self] message, _ in
                await self?.handleStreamScaleChangeMessage(message)
            },
            .streamRefreshRateChange: { [weak self] message, _ in
                await self?.handleStreamRefreshRateChangeMessage(message)
            },
            .streamReady: { [weak self] message, _ in
                await self?.handleStreamReadyMessage(message)
            },
            .streamEncoderSettingsChange: { [weak self] message, _ in
                await self?.handleStreamEncoderSettingsChangeMessage(message)
            },
            .desktopCursorPresentationChange: { [weak self] message, _ in
                await self?.handleDesktopCursorPresentationChangeMessage(message)
            },
            .stopStream: { [weak self] message, _ in
                await self?.handleStopStreamMessage(message)
            },
            .keyframeRequest: { [weak self] message, _ in
                await self?.handleKeyframeRequestMessage(message)
            },
            .ping: { [weak self] _, clientContext in
                self?.handlePingMessage(clientContext: clientContext)
            },
            .inputEvent: { [weak self] message, clientContext in
                await self?.handleInputEventMessage(message, from: clientContext.client)
            },
            .disconnect: { [weak self] message, clientContext in
                await self?.handleDisconnectMessage(message, from: clientContext.client)
            },
            .appListRequest: { [weak self] message, clientContext in
                await self?.handleAppListRequest(message, from: clientContext)
            },
            .selectApp: { [weak self] message, clientContext in
                await self?.handleSelectApp(message, from: clientContext)
            },
            .appWindowSwapRequest: { [weak self] message, clientContext in
                await self?.handleAppWindowSwapRequest(message, from: clientContext)
            },
            .appWindowCloseAlertActionRequest: { [weak self] message, clientContext in
                await self?.handleAppWindowCloseAlertActionRequest(message, from: clientContext)
            },
            .menuActionRequest: { [weak self] message, clientContext in
                await self?.handleMenuActionRequest(message, from: clientContext)
            },
            .hostHardwareIconRequest: { [weak self] message, clientContext in
                await self?.handleHostHardwareIconRequest(message, from: clientContext)
            },
            .hostWallpaperRequest: { [weak self] message, clientContext in
                await self?.handleHostWallpaperRequest(message, from: clientContext)
            },
            .remoteClientStreamOptionsState: { [weak self] message, clientContext in
                await self?.handleRemoteClientStreamOptionsState(message, from: clientContext)
            },
            .hostSupportLogArchiveRequest: { [weak self] message, clientContext in
                await self?.handleHostSupportLogArchiveRequest(message, from: clientContext)
            },
            .startDesktopStream: { [weak self] message, clientContext in
                await self?.handleStartDesktopStream(message, from: clientContext)
            },
            .stopDesktopStream: { [weak self] message, _ in
                await self?.handleStopDesktopStream(message)
            },
            .qualityTestRequest: { [weak self] message, clientContext in
                await self?.handleQualityTestRequest(message, from: clientContext)
            },
            .qualityTestCancel: { [weak self] message, clientContext in
                await self?.handleQualityTestCancel(message, from: clientContext)
            },
            .hostSoftwareUpdateStatusRequest: { [weak self] message, clientContext in
                await self?.handleHostSoftwareUpdateStatusRequest(message, from: clientContext)
            },
            .hostSoftwareUpdateInstallRequest: { [weak self] message, clientContext in
                await self?.handleHostSoftwareUpdateInstallRequest(message, from: clientContext)
            },
            .sharedClipboardUpdate: { [weak self] message, clientContext in
                await self?.handleSharedClipboardUpdate(message, from: clientContext)
            },
            .streamPauseAll: { [weak self] _, _ in
                await self?.handleStreamPauseAll()
            },
            .streamResumeAll: { [weak self] _, _ in
                await self?.handleStreamResumeAll()
            }
        ]
    }

    func handleClientMessage(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        MirageLogger.host("Received message type: \(message.type) from \(clientContext.client.name)")
        guard let handler = controlMessageHandlers[message.type] else {
            MirageLogger.host("Unhandled message type: \(message.type)")
            return
        }
        await handler(message, clientContext)
    }

    private func handleStartStreamMessage(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(StartStreamMessage.self)
            guard !disconnectingClientIDs.contains(clientContext.client.id),
                  clientsByID[clientContext.client.id] != nil else {
                MirageLogger.host("Ignoring startStream from disconnected client \(clientContext.client.name)")
                return
            }
            await cancelQualityTest(
                for: clientContext.client.id,
                reason: "app stream startup"
            )
            MirageLogger.host("Client requested stream for window \(request.windowID)")

            await refreshSessionStateIfNeeded()
            guard sessionState == .ready else {
                MirageLogger.host("Rejecting startStream while session is \(sessionState)")
                await sendSessionState(to: clientContext)
                return
            }

            guard let window = availableWindows.first(where: { $0.id == request.windowID }) else {
                MirageLogger.host("Window not found: \(request.windowID)")
                sendControlError(
                    .windowNotFound,
                    message: "Window \(request.windowID) not found",
                    to: clientContext
                )
                return
            }

            guard let displayWidth = request.displayWidth,
                  let displayHeight = request.displayHeight,
                  displayWidth > 0,
                  displayHeight > 0 else {
                MirageLogger.host("Rejecting startStream without display size for window \(request.windowID)")
                sendControlError(
                    .invalidMessage,
                    message: "startStream requires displayWidth/displayHeight",
                    to: clientContext
                )
                return
            }
            let clientDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
            MirageLogger.host("Client display size (points): \(displayWidth)x\(displayHeight)")

            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)

            let keyFrameInterval = request.keyFrameInterval
            let colorDepth = request.colorDepth
            let bitrate = request.bitrate
            let latencyMode = request.latencyMode ?? .lowestLatency
            let performanceMode = request.performanceMode ?? .standard
            let allowRuntimeQualityAdjustment = request.allowRuntimeQualityAdjustment
            let lowLatencyHighResolutionCompressionBoost = request.lowLatencyHighResolutionCompressionBoost ?? true
            let disableResolutionCap = request.disableResolutionCap ?? false
            let requestedScale = request.streamScale ?? 1.0
            let audioConfiguration = request.audioConfiguration ?? .default
            let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                pathKind: pathKind
            )
            MirageLogger.host("Frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)")
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Performance mode: \(performanceMode.displayName)")

            pendingLightsOutSetup = true
            await beginPendingAppStreamLightsOutSetup()
            try await startStream(
                for: window,
                to: clientContext.client,
                clientDisplayResolution: clientDisplayResolution,
                clientScaleFactor: request.scaleFactor,
                keyFrameInterval: keyFrameInterval,
                streamScale: requestedScale,
                targetFrameRate: targetFrameRate,
                colorDepth: colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                bitrate: bitrate,
                latencyMode: latencyMode,
                performanceMode: performanceMode,
                allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: lowLatencyHighResolutionCompressionBoost,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                upscalingMode: request.upscalingMode,
                codec: request.codec
            )
            pendingLightsOutSetup = false
            await endPendingAppStreamLightsOutSetup()
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
            }
            MirageLogger.error(.host, error: error, message: "Failed to handle startStream: ")
            let errorCode: ErrorMessage.ErrorCode = if error is WindowStreamStartError {
                .virtualDisplayStartFailed
            } else {
                .encodingError
            }
            sendControlError(
                errorCode,
                message: "Failed to start stream: \(error.localizedDescription)",
                to: clientContext
            )
        }
    }

    private func handleDisplayResolutionChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(DisplayResolutionChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested display size change for stream \(request.streamID): " +
                        "\(request.displayWidth)x\(request.displayHeight) pts"
                )
            let baseResolution = CGSize(width: request.displayWidth, height: request.displayHeight)
            await handleDisplayResolutionChange(
                streamID: request.streamID,
                newResolution: baseResolution
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle displayResolutionChange: ")
        }
    }

    private func handleStreamScaleChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamScaleChangeMessage.self)
            MirageLogger
                .host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
            await handleStreamScaleChange(streamID: request.streamID, streamScale: request.streamScale)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamScaleChange: ")
        }
    }

    private func handleStreamRefreshRateChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamRefreshRateChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested refresh rate override for stream \(request.streamID): \(request.maxRefreshRate)Hz"
                )
            await handleStreamRefreshRateChange(
                streamID: request.streamID,
                maxRefreshRate: request.maxRefreshRate,
                forceDisplayRefresh: request.forceDisplayRefresh ?? false
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamRefreshRateChange: ")
        }
    }

    private func handleStreamEncoderSettingsChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamEncoderSettingsChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested encoder settings change for stream \(request.streamID): " +
                        "colorDepth=\(request.colorDepth?.displayName ?? "unchanged"), " +
                        "bitrate=\(request.bitrate.map(String.init) ?? "unchanged"), " +
                        "scale=\(request.streamScale.map(String.init(describing:)) ?? "unchanged")"
                )
            await handleStreamEncoderSettingsChange(request)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamEncoderSettingsChange: ")
        }
    }

    private func handleDesktopCursorPresentationChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(DesktopCursorPresentationChangeMessage.self)
            MirageLogger.host(
                "Client requested desktop cursor presentation change for stream \(request.streamID): " +
                    "source=\(request.cursorPresentation.source.rawValue), " +
                    "lockClientCursor=\(request.cursorPresentation.lockClientCursorWhenUsingHostCursor)"
            )
            await handleDesktopCursorPresentationChange(request)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle desktopCursorPresentationChange: ")
        }
    }

    private func handleStopStreamMessage(_ message: ControlMessage) async {
        guard let request = try? message.decode(StopStreamMessage.self) else { return }
        guard let session = activeSessionByStreamID[request.streamID] else { return }

        let appSession = await appStreamManager.getSessionForWindow(session.window.id)
        let shouldAttemptHostWindowClose = Self.clientWindowCloseHostWindowCloseDecision(
            origin: request.origin,
            closeHostWindowOnClientWindowClose: closeHostWindowOnClientWindowClose,
            hasAppStreamSession: appSession != nil
        ) == .attemptHostWindowClose

        if shouldAttemptHostWindowClose, let appSession {
            await handleHostWindowCloseAttemptForClientWindowClose(
                session: session,
                appSession: appSession
            )
        }

        await stopStream(session, minimizeWindow: request.minimizeWindow)
    }

    private func handleStreamReadyMessage(_ message: ControlMessage) async {
        do {
            let ready = try message.decode(StreamReadyMessage.self)
            await acknowledgePendingStartupAttempt(
                streamID: ready.streamID,
                startupAttemptID: ready.startupAttemptID,
                kind: ready.kind
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamReady: ")
        }
    }

    private func handleKeyframeRequestMessage(_ message: ControlMessage) async {
        if let request = try? message.decode(KeyframeRequestMessage.self),
           let context = streamsByID[request.streamID] {
            await context.requestKeyframe()
        }
    }

    private func handlePingMessage(clientContext: ClientContext) {
        let pong = ControlMessage(type: .pong)
        clientContext.sendBestEffort(pong)
    }

    private func handleInputEventMessage(_ message: ControlMessage, from client: MirageConnectedClient) async {
        do {
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            if case let .windowResize(resizeEvent) = inputMessage.event {
                MirageLogger
                    .host(
                        "Received RESIZE event: \(resizeEvent.newSize) pts, scale: \(resizeEvent.scaleFactor), pixels: \(resizeEvent.pixelSize)"
                    )
            }
            if let session = activeSessionByStreamID[inputMessage.streamID] {
                delegate?.hostService(
                    self,
                    didReceiveInputEvent: inputMessage.event,
                    forWindow: session.window,
                    fromClient: client
                )
            } else {
                MirageLogger.host("No session found for stream \(inputMessage.streamID)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode input event: ")
        }
    }

    private func handleDisconnectMessage(_ message: ControlMessage, from client: MirageConnectedClient) async {
        if let disconnect = try? message.decode(DisconnectMessage.self) {
            MirageLogger.host("Client \(client.name) disconnected: \(disconnect.reason.rawValue)")
        } else {
            MirageLogger.host("Client \(client.name) disconnected")
        }
        await disconnectClient(client)
        delegate?.hostService(self, didDisconnectClient: client)
    }

    // MARK: - Stream Pause/Resume (Client Backgrounding)

    private func handleStreamPauseAll() async {
        let contextCount = streamsByID.count
        guard contextCount > 0 else { return }
        MirageLogger.host("Pausing all streams (\(contextCount)) for client background")
        for (_, context) in streamsByID {
            await context.pauseForClientBackground()
        }
    }

    private func handleStreamResumeAll() async {
        let contextCount = streamsByID.count
        guard contextCount > 0 else { return }
        MirageLogger.host("Resuming all streams (\(contextCount)) after client foreground")
        for (_, context) in streamsByID {
            await context.resumeAfterClientForeground()
        }
    }

    private func handleAppWindowCloseAlertActionRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let request = try message.decode(AppWindowCloseAlertActionRequestMessage.self)
            let result = await performAppWindowCloseAlertAction(
                alertToken: request.alertToken,
                actionID: request.actionID,
                presentingStreamID: request.presentingStreamID,
                clientID: clientContext.client.id
            )
            if let response = try? ControlMessage(type: .appWindowCloseAlertActionResult, content: result) {
                clientContext.sendBestEffort(response)
            }
        } catch {
            let fallback = AppWindowCloseAlertActionResultMessage(
                alertToken: "",
                actionID: "",
                success: false,
                reason: error.localizedDescription
            )
            if let response = try? ControlMessage(type: .appWindowCloseAlertActionResult, content: fallback) {
                clientContext.sendBestEffort(response)
            }
        }
    }
}
#endif
