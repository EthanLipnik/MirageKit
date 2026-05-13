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
        to clientContext: ClientContext
    ) {
        let payload = ErrorMessage(code: code, message: message)
        guard clientContext.sendBestEffort(.error, content: payload) else {
            MirageLogger.error(.host, "Failed to encode error response: \(message)")
            return
        }
    }

    func registerControlMessageHandlers() {
        controlMessageHandlers = [
            .startStream: .messageAndClient { [weak self] message, clientContext in
                await self?.handleStartStreamMessage(message, from: clientContext)
            },
            .displayResolutionChange: .message { [weak self] message in
                await self?.handleDisplayResolutionChangeMessage(message)
            },
            .streamScaleChange: .message { [weak self] message in
                await self?.handleStreamScaleChangeMessage(message)
            },
            .streamRefreshRateChange: .message { [weak self] message in
                await self?.handleStreamRefreshRateChangeMessage(message)
            },
            .streamReady: .message { [weak self] message in
                await self?.handleStreamReadyMessage(message)
            },
            .streamEncoderSettingsChange: .message { [weak self] message in
                await self?.handleStreamEncoderSettingsChangeMessage(message)
            },
            .desktopCursorPresentationChange: .message { [weak self] message in
                await self?.handleDesktopCursorPresentationChangeMessage(message)
            },
            .stopStream: .message { [weak self] message in
                await self?.handleStopStreamMessage(message)
            },
            .keyframeRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleKeyframeRequestMessage(message, from: clientContext)
            },
            .ping: .client { clientContext in
                clientContext.sendBestEffort(.pong)
            },
            .inputEvent: .message { [weak self] message in
                await self?.handleInputEventMessage(message)
            },
            .disconnect: .messageAndClient { [weak self] message, clientContext in
                await self?.handleDisconnectMessage(message, from: clientContext)
            },
            .appListRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleAppListRequest(message, from: clientContext)
            },
            .selectApp: .messageAndClient { [weak self] message, clientContext in
                await self?.handleSelectApp(message, from: clientContext)
            },
            .appWindowSwapRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleAppWindowSwapRequest(message, from: clientContext)
            },
            .appWindowCloseAlertActionRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleAppWindowCloseAlertActionRequest(message, from: clientContext)
            },
            .menuActionRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleMenuActionRequest(message, from: clientContext)
            },
            .hostHardwareIconRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleHostHardwareIconRequest(message, from: clientContext)
            },
            .hostWallpaperRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleHostWallpaperRequest(message, from: clientContext)
            },
            .remoteClientStreamOptionsState: .messageAndClient { [weak self] message, clientContext in
                await self?.handleRemoteClientStreamOptionsState(message, from: clientContext)
            },
            .hostSupportLogArchiveRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleHostSupportLogArchiveRequest(message, from: clientContext)
            },
            .startDesktopStream: .messageAndClient { [weak self] message, clientContext in
                await self?.handleStartDesktopStream(message, from: clientContext)
            },
            .stopDesktopStream: .message { [weak self] message in
                await self?.handleStopDesktopStream(message)
            },
            .qualityTestRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleQualityTestRequest(message, from: clientContext)
            },
            .qualityTestCancel: .messageAndClient { [weak self] message, clientContext in
                await self?.handleQualityTestCancel(message, from: clientContext)
            },
            .hostSoftwareUpdateStatusRequest: .messageAndClient { [weak self] message, clientContext in
                await self?.handleHostSoftwareUpdateStatusRequest(message, from: clientContext)
            },
            .hostSoftwareUpdateInstallRequest: .client { [weak self] clientContext in
                await self?.handleHostSoftwareUpdateInstallRequest(from: clientContext)
            },
            .hostApplicationRestartRequest: .client { [weak self] clientContext in
                await self?.handleHostApplicationRestartRequest(from: clientContext)
            },
            .sharedClipboardUpdate: .messageAndClient { [weak self] message, clientContext in
                await self?.handleSharedClipboardUpdate(message, from: clientContext)
            },
            .streamPauseAll: .messageAndClient { [weak self] message, clientContext in
                await self?.handleStreamPauseAll(message, from: clientContext)
            },
            .streamResumeAll: .client { [weak self] clientContext in
                await self?.handleStreamResumeAll(from: clientContext)
            },
            .cancelStreamSetup: .messageAndClient { [weak self] message, clientContext in
                await self?.handleCancelStreamSetup(message, from: clientContext)
            },
            .startCustomStream: .messageAndClient { [weak self] message, clientContext in
                await self?.handleStartCustomStream(message, from: clientContext)
            },
            .stopCustomStream: .messageAndClient { [weak self] message, clientContext in
                await self?.handleStopCustomStream(message, from: clientContext)
            }
        ]
    }

    func handleClientMessage(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        if Self.shouldLogReceivedControlMessageType(message.type) {
            MirageLogger.host("Received message type: \(message.type) from \(clientContext.client.name)")
        }
        guard let handler = controlMessageHandlers[message.type] else {
            MirageLogger.host("Unhandled message type: \(message.type)")
            return
        }
        switch handler {
        case let .messageAndClient(handle):
            await handle(message, clientContext)
        case let .message(handle):
            await handle(message)
        case let .client(handle):
            await handle(clientContext)
        }
    }

    nonisolated static func shouldLogReceivedControlMessageType(_ type: ControlMessageType) -> Bool {
        type != .receiverMediaFeedback
    }

    private func handleStopStreamMessage(_ message: ControlMessage) async {
        let request: StopStreamMessage
        do {
            request = try message.decode(StopStreamMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle stopStream: ")
            return
        }

        guard let session = activeSessionByStreamID[request.streamID] else { return }

        let appSession = await appStreamManager.sessionForWindow(session.window.id)
        if request.origin == .clientWindowClosed,
           closeHostWindowOnClientWindowClose,
           let appSession {
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

    private func handleKeyframeRequestMessage(_ message: ControlMessage, from clientContext: ClientContext) async {
        let request: KeyframeRequestMessage
        do {
            request = try message.decode(KeyframeRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle keyframeRequest: ")
            return
        }

        guard let context = streamsByID[request.streamID] else { return }
        let ack = await context.requestKeyframe()
        clientContext.queueBestEffort(.keyframeRecoveryAck, content: ack)
    }

    private func handleInputEventMessage(_ message: ControlMessage) async {
        do {
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            if case let .windowResize(resizeEvent) = inputMessage.event {
                MirageLogger
                    .host(
                        "Received RESIZE event: \(resizeEvent.newSize) pts, scale: \(resizeEvent.scaleFactor), pixels: \(resizeEvent.pixelSize)"
                    )
            }
            if let session = activeSessionByStreamID[inputMessage.streamID] {
                delegate?.didReceiveInputEvent(
                    inputMessage.event,
                    forWindow: session.window
                )
            } else {
                MirageLogger.host("No session found for stream \(inputMessage.streamID)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode input event: ")
        }
    }

    private func handleDisconnectMessage(_ message: ControlMessage, from clientContext: ClientContext) async {
        let client = clientContext.client
        do {
            let disconnect = try message.decode(DisconnectMessage.self)
            MirageLogger.host("Client \(client.name) disconnected: \(disconnect.reason.rawValue)")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode disconnect message: ")
            MirageLogger.host("Client \(client.name) disconnected")
        }
        await disconnectClient(
            client,
            sessionID: clientContext.sessionID,
            notifyClient: false
        )
        delegate?.didDisconnectClient(client)
    }

}
#endif
