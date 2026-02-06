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
    func handleClientMessage(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    )
    async {
        MirageLogger.host("Received message type: \(message.type) from \(client.name)")
        switch message.type {
        case .startStream:
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
                    MirageLogger
                        .host("Client initial size (legacy): \(pixelWidth)x\(pixelHeight) px -> \(pointSize) pts")
                    onResizeWindowForStream?(window, pointSize)
                }

                let clientMaxRefreshRate = request.maxRefreshRate
                let targetFrameRate = resolvedTargetFrameRate(clientMaxRefreshRate)

                let keyFrameInterval = request.keyFrameInterval
                let pixelFormat = request.pixelFormat
                let colorSpace = request.colorSpace
                let bitrate = request.bitrate
                let requestedScale = request.streamScale ?? 1.0
                let latencyMode = request.latencyMode ?? .smoothest
                MirageLogger
                    .host(
                        "Frame rate: \(targetFrameRate)fps (client max=\(clientMaxRefreshRate)Hz)"
                    )

                try await startStream(
                    for: window,
                    to: client,
                    dataPort: request.dataPort,
                    clientDisplayResolution: clientDisplayResolution,
                    keyFrameInterval: keyFrameInterval,
                    streamScale: requestedScale,
                    latencyMode: latencyMode,
                    targetFrameRate: targetFrameRate,
                    pixelFormat: pixelFormat,
                    colorSpace: colorSpace,
                    captureQueueDepth: request.captureQueueDepth,
                    bitrate: bitrate
                )
            } catch {
                MirageLogger.error(.host, "Failed to handle startStream: \(error)")
            }

        case .displayResolutionChange:
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

        case .streamScaleChange:
            do {
                let request = try message.decode(StreamScaleChangeMessage.self)
                MirageLogger
                    .host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
                await handleStreamScaleChange(streamID: request.streamID, streamScale: request.streamScale)
            } catch {
                MirageLogger.error(.host, "Failed to handle streamScaleChange: \(error)")
            }

        case .streamRefreshRateChange:
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

        case .streamEncoderSettingsChange:
            do {
                let request = try message.decode(StreamEncoderSettingsChangeMessage.self)
                MirageLogger
                    .host(
                        "Client requested encoder settings change for stream \(request.streamID): " +
                            "pixelFormat=\(request.pixelFormat?.displayName ?? "unchanged"), " +
                            "color=\(request.colorSpace?.displayName ?? "unchanged"), " +
                            "bitrate=\(request.bitrate.map(String.init) ?? "unchanged"), " +
                            "scale=\(request.streamScale.map(String.init(describing:)) ?? "unchanged")"
                    )
                await handleStreamEncoderSettingsChange(request)
            } catch {
                MirageLogger.error(.host, "Failed to handle streamEncoderSettingsChange: \(error)")
            }

        case .stopStream:
            if let request = try? message.decode(StopStreamMessage.self) {
                if let session = activeStreams.first(where: { $0.id == request.streamID }) { await stopStream(session, minimizeWindow: request.minimizeWindow) }
            }

        case .keyframeRequest:
            if let request = try? message.decode(KeyframeRequestMessage.self),
               let context = streamsByID[request.streamID] {
                await context.requestKeyframe()
            }

        case .ping:
            let pong = ControlMessage(type: .pong)
            connection.send(content: pong.serialize(), completion: .idempotent)

        case .inputEvent:
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

        case .disconnect:
            if let disconnect = try? message.decode(DisconnectMessage.self) { MirageLogger.host("Client \(client.name) disconnected: \(disconnect.reason.rawValue)") } else {
                MirageLogger.host("Client \(client.name) disconnected")
            }
            await disconnectClient(client)
            delegate?.hostService(self, didDisconnectClient: client)

        case .unlockRequest:
            await handleUnlockRequest(message, from: client, connection: connection)

        case .appListRequest:
            await handleAppListRequest(message, from: client, connection: connection)

        case .selectApp:
            await handleSelectApp(message, from: client, connection: connection)

        case .closeWindowRequest:
            await handleCloseWindowRequest(message, from: client, connection: connection)

        case .streamPaused:
            await handleStreamPaused(message, from: client)

        case .streamResumed:
            await handleStreamResumed(message, from: client)

        case .cancelCooldown:
            await handleCancelCooldown(message, from: client, connection: connection)

        case .menuActionRequest:
            await handleMenuActionRequest(message, from: client, connection: connection)

        case .startDesktopStream:
            await handleStartDesktopStream(message, from: client, connection: connection)

        case .stopDesktopStream:
            await handleStopDesktopStream(message)

        case .qualityTestRequest:
            await handleQualityTestRequest(message, from: client, connection: connection)

        case .qualityProbeRequest:
            await handleQualityProbeRequest(message, from: client, connection: connection)

        default:
            MirageLogger.host("Unhandled message type: \(message.type)")
        }
    }

    func sendVideoData(_ data: Data, header _: FrameHeader, to client: MirageConnectedClient) async {
        if let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) { clientContext.sendVideoPacket(data) }
    }
}
#endif
