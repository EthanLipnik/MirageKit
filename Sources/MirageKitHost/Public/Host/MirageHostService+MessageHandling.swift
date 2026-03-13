//
//  MirageHostService+MessageHandling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message routing.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    private func sendControlError(
        _ code: ErrorMessage.ErrorCode,
        message: String,
        streamID: StreamID? = nil,
        over connection: NWConnection
    ) {
        let payload = ErrorMessage(code: code, message: message, streamID: streamID)
        guard let response = try? ControlMessage(type: .error, content: payload) else {
            MirageLogger.error(.host, "Failed to encode error response: \(message)")
            return
        }
        connection.send(content: response.serialize(), completion: .idempotent)
    }

    func registerControlMessageHandlers() {
        controlMessageHandlers = [
            .startStream: { [weak self] message, client, connection in
                await self?.handleStartStreamMessage(message, from: client, connection: connection)
            },
            .displayResolutionChange: { [weak self] message, _, _ in
                await self?.handleDisplayResolutionChangeMessage(message)
            },
            .streamScaleChange: { [weak self] message, _, _ in
                await self?.handleStreamScaleChangeMessage(message)
            },
            .streamRefreshRateChange: { [weak self] message, _, _ in
                await self?.handleStreamRefreshRateChangeMessage(message)
            },
            .streamEncoderSettingsChange: { [weak self] message, _, _ in
                await self?.handleStreamEncoderSettingsChangeMessage(message)
            },
            .stopStream: { [weak self] message, _, _ in
                await self?.handleStopStreamMessage(message)
            },
            .keyframeRequest: { [weak self] message, _, _ in
                await self?.handleKeyframeRequestMessage(message)
            },
            .ping: { [weak self] _, _, connection in
                self?.handlePingMessage(connection: connection)
            },
            .inputEvent: { [weak self] message, client, _ in
                await self?.handleInputEventMessage(message, from: client)
            },
            .disconnect: { [weak self] message, client, _ in
                await self?.handleDisconnectMessage(message, from: client)
            },
            .unlockRequest: { [weak self] message, client, connection in
                await self?.handleUnlockRequest(message, from: client, connection: connection)
            },
            .appListRequest: { [weak self] message, client, connection in
                await self?.handleAppListRequest(message, from: client, connection: connection)
            },
            .selectApp: { [weak self] message, client, connection in
                await self?.handleSelectApp(message, from: client, connection: connection)
            },
            .appWindowSwapRequest: { [weak self] message, client, connection in
                await self?.handleAppWindowSwapRequest(message, from: client, connection: connection)
            },
            .appWindowCloseAlertActionRequest: { [weak self] message, client, connection in
                await self?.handleAppWindowCloseAlertActionRequest(message, from: client, connection: connection)
            },
            .menuActionRequest: { [weak self] message, client, connection in
                await self?.handleMenuActionRequest(message, from: client, connection: connection)
            },
            .hostHardwareIconRequest: { [weak self] message, client, connection in
                await self?.handleHostHardwareIconRequest(message, from: client, connection: connection)
            },
            .startDesktopStream: { [weak self] message, client, connection in
                await self?.handleStartDesktopStream(message, from: client, connection: connection)
            },
            .stopDesktopStream: { [weak self] message, _, _ in
                await self?.handleStopDesktopStream(message)
            },
            .qualityTestRequest: { [weak self] message, client, connection in
                await self?.handleQualityTestRequest(message, from: client, connection: connection)
            },
            .hostSoftwareUpdateStatusRequest: { [weak self] message, client, connection in
                await self?.handleHostSoftwareUpdateStatusRequest(message, from: client, connection: connection)
            },
            .hostSoftwareUpdateInstallRequest: { [weak self] message, client, connection in
                await self?.handleHostSoftwareUpdateInstallRequest(message, from: client, connection: connection)
            },
            .sharedClipboardUpdate: { [weak self] message, client, connection in
                await self?.handleSharedClipboardUpdate(message, from: client, connection: connection)
            }
        ]
    }

    func handleClientMessage(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        MirageLogger.host("Received message type: \(message.type) from \(client.name)")
        guard let handler = controlMessageHandlers[message.type] else {
            MirageLogger.host("Unhandled message type: \(message.type)")
            return
        }
        await handler(message, client, connection)
    }

    func sendVideoData(_ data: Data, header _: FrameHeader, to client: MirageConnectedClient) async {
        if let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) { clientContext.sendVideoPacket(data) }
    }

    private func handleStartStreamMessage(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(StartStreamMessage.self)
            guard !disconnectingClientIDs.contains(client.id),
                  clientsByID[client.id] != nil else {
                MirageLogger.host("Ignoring startStream from disconnected client \(client.name)")
                return
            }
            MirageLogger.host("Client requested stream for window \(request.windowID)")

            await refreshSessionStateIfNeeded()
            guard sessionState == .ready else {
                MirageLogger.host("Rejecting startStream while session is \(sessionState)")
                if let clientContext = clientsByConnection[ObjectIdentifier(connection)] { await sendSessionState(to: clientContext) }
                return
            }

            guard let window = availableWindows.first(where: { $0.id == request.windowID }) else {
                MirageLogger.host("Window not found: \(request.windowID)")
                sendControlError(
                    .windowNotFound,
                    message: "Window \(request.windowID) not found",
                    over: connection
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
                    over: connection
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
            let latencyMode = request.latencyMode ?? .auto
            let performanceMode = request.performanceMode ?? .standard
            let allowRuntimeQualityAdjustment = request.allowRuntimeQualityAdjustment
            let lowLatencyHighResolutionCompressionBoost = request.lowLatencyHighResolutionCompressionBoost ?? true
            let temporaryDegradationMode = request.temporaryDegradationMode ?? .off
            let disableResolutionCap = request.disableResolutionCap ?? false
            let requestedScale = request.streamScale ?? 1.0
            let audioConfiguration = request.audioConfiguration ?? .default
            MirageLogger.host("Frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)")
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Performance mode: \(performanceMode.displayName)")

            pendingLightsOutSetup = true
            await beginPendingAppStreamLightsOutSetup()
            _ = try await startStream(
                for: window,
                to: client,
                dataPort: request.dataPort,
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
                temporaryDegradationMode: temporaryDegradationMode,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration
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
                over: connection
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

    private func handleKeyframeRequestMessage(_ message: ControlMessage) async {
        if let request = try? message.decode(KeyframeRequestMessage.self),
           let context = streamsByID[request.streamID] {
            await context.requestKeyframe()
        }
    }

    private func handlePingMessage(connection: NWConnection) {
        let pong = ControlMessage(type: .pong)
        connection.send(content: pong.serialize(), completion: .idempotent)
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

    private func handleAppWindowCloseAlertActionRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        do {
            let request = try message.decode(AppWindowCloseAlertActionRequestMessage.self)
            let result = await performAppWindowCloseAlertAction(
                alertToken: request.alertToken,
                actionID: request.actionID,
                presentingStreamID: request.presentingStreamID,
                clientID: client.id
            )
            if let response = try? ControlMessage(type: .appWindowCloseAlertActionResult, content: result) {
                connection.send(content: response.serialize(), completion: .idempotent)
            }
        } catch {
            let fallback = AppWindowCloseAlertActionResultMessage(
                alertToken: "",
                actionID: "",
                success: false,
                reason: error.localizedDescription
            )
            if let response = try? ControlMessage(type: .appWindowCloseAlertActionResult, content: fallback) {
                connection.send(content: response.serialize(), completion: .idempotent)
            }
        }
    }
}
#endif
