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
            .closeWindowRequest: { [weak self] message, client, connection in
                await self?.handleCloseWindowRequest(message, from: client, connection: connection)
            },
            .streamPaused: { [weak self] message, client, _ in
                await self?.handleStreamPaused(message, from: client)
            },
            .streamResumed: { [weak self] message, client, _ in
                await self?.handleStreamResumed(message, from: client)
            },
            .cancelCooldown: { [weak self] message, client, connection in
                await self?.handleCancelCooldown(message, from: client, connection: connection)
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
        do {
            let request = try message.decode(StartStreamMessage.self)
            MirageLogger.host("Client requested stream for window \(request.windowID)")

            await refreshSessionStateIfNeeded()
            guard sessionState == .active else {
                MirageLogger.host("Rejecting startStream while session is \(sessionState)")
                if let clientContext = clientsByConnection[ObjectIdentifier(connection)] { await sendSessionState(to: clientContext) }
                return
            }

            guard let window = availableWindows.first(where: { $0.id == request.windowID }) else {
                MirageLogger.host("Window not found: \(request.windowID)")
                return
            }

            var clientDisplayResolution: CGSize?
            if let displayWidth = request.displayWidth, let displayHeight = request.displayHeight,
               displayWidth > 0, displayHeight > 0 {
                clientDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
                MirageLogger.host("Client display size (points): \(displayWidth)x\(displayHeight)")
            }

            if clientDisplayResolution == nil,
               let pixelWidth = request.pixelWidth, let pixelHeight = request.pixelHeight,
               pixelWidth > 0, pixelHeight > 0,
               let scaleFactor = request.scaleFactor, scaleFactor > 0 {
                let pointSize = CGSize(
                    width: CGFloat(pixelWidth) / scaleFactor,
                    height: CGFloat(pixelHeight) / scaleFactor
                )
                MirageLogger.host("Client initial size (legacy): \(pixelWidth)x\(pixelHeight) px -> \(pointSize) pts")
                onResizeWindowForStream?(window, pointSize)
            }

            let clientMaxRefreshRate = request.maxRefreshRate
            let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)

            let keyFrameInterval = request.keyFrameInterval
            let bitDepth = request.bitDepth
            let bitrate = request.bitrate
            let allowRuntimeQualityAdjustment = request.allowRuntimeQualityAdjustment
            let disableResolutionCap = request.disableResolutionCap ?? false
            let requestedScale = request.streamScale ?? 1.0
            let latencyMode = request.latencyMode ?? .auto
            let audioConfiguration = request.audioConfiguration ?? .default
            MirageLogger.host("Frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)")

            _ = try await startStream(
                for: window,
                to: client,
                dataPort: request.dataPort,
                clientDisplayResolution: clientDisplayResolution,
                keyFrameInterval: keyFrameInterval,
                streamScale: requestedScale,
                latencyMode: latencyMode,
                targetFrameRate: targetFrameRate,
                bitDepth: bitDepth,
                captureQueueDepth: request.captureQueueDepth,
                bitrate: bitrate,
                allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration
            )
        } catch {
            MirageLogger.error(.host, "Failed to handle startStream: \(error)")
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
            MirageLogger.error(.host, "Failed to handle displayResolutionChange: \(error)")
        }
    }

    private func handleStreamScaleChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamScaleChangeMessage.self)
            MirageLogger
                .host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
            await handleStreamScaleChange(streamID: request.streamID, streamScale: request.streamScale)
        } catch {
            MirageLogger.error(.host, "Failed to handle streamScaleChange: \(error)")
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
            MirageLogger.error(.host, "Failed to handle streamRefreshRateChange: \(error)")
        }
    }

    private func handleStreamEncoderSettingsChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamEncoderSettingsChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested encoder settings change for stream \(request.streamID): " +
                        "bitDepth=\(request.bitDepth?.displayName ?? "unchanged"), " +
                        "bitrate=\(request.bitrate.map(String.init) ?? "unchanged"), " +
                        "scale=\(request.streamScale.map(String.init(describing:)) ?? "unchanged")"
                )
            await handleStreamEncoderSettingsChange(request)
        } catch {
            MirageLogger.error(.host, "Failed to handle streamEncoderSettingsChange: \(error)")
        }
    }

    private func handleStopStreamMessage(_ message: ControlMessage) async {
        guard let request = try? message.decode(StopStreamMessage.self) else { return }
        if let session = activeStreams.first(where: { $0.id == request.streamID }) {
            await stopStream(session, minimizeWindow: request.minimizeWindow)
        }
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
            let inputMessage = try message.decode(InputEventMessage.self)
            if case let .windowResize(resizeEvent) = inputMessage.event {
                MirageLogger
                    .host(
                        "Received RESIZE event: \(resizeEvent.newSize) pts, scale: \(resizeEvent.scaleFactor), pixels: \(resizeEvent.pixelSize)"
                    )
            }
            if let session = activeStreams.first(where: { $0.id == inputMessage.streamID }) {
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
            MirageLogger.error(.host, "Failed to decode input event: \(error)")
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
}
#endif
