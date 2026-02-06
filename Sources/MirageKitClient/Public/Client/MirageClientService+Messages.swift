//
//  MirageClientService+Messages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message routing.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func setupMessageHandlers() {
        Task {
            await transport?.setControlMessageHandler { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handleControlMessage(message)
                }
            }

            await transport?.setVideoPacketHandler { [weak self] data, header in
                Task { @MainActor [weak self] in
                    await self?.handleVideoPacket(data, header: header)
                }
            }
        }
    }

    func handleControlMessage(_ message: ControlMessage) async {
        switch message.type {
        case .helloResponse:
            handleHelloResponse(message)
        case .windowList:
            handleWindowList(message)
        case .windowUpdate:
            handleWindowUpdate(message)
        case .streamStarted:
            handleStreamStarted(message)
        case .streamStopped:
            handleStreamStopped(message)
        case .streamMetricsUpdate:
            handleStreamMetricsUpdate(message)
        case .error:
            handleErrorMessage(message)
        case .disconnect:
            await handleDisconnectMessage(message)
        case .cursorUpdate:
            handleCursorUpdate(message)
        case .cursorPositionUpdate:
            handleCursorPositionUpdate(message)
        case .contentBoundsUpdate:
            handleContentBoundsUpdate(message)
        case .sessionStateUpdate:
            handleSessionStateUpdate(message)
        case .unlockResponse:
            handleUnlockResponse(message)
        case .loginDisplayReady:
            handleLoginDisplayReady(message)
        case .loginDisplayStopped:
            handleLoginDisplayStopped(message)
        case .desktopStreamStarted:
            handleDesktopStreamStarted(message)
        case .desktopStreamStopped:
            handleDesktopStreamStopped(message)
        case .appList:
            handleAppList(message)
        case .appStreamStarted:
            handleAppStreamStarted(message)
        case .windowAddedToStream:
            handleWindowAddedToStream(message)
        case .windowCooldownStarted:
            handleWindowCooldownStarted(message)
        case .windowCooldownCancelled:
            handleWindowCooldownCancelled(message)
        case .returnToAppSelection:
            handleReturnToAppSelection(message)
        case .appTerminated:
            handleAppTerminated(message)
        case .menuBarUpdate:
            handleMenuBarUpdate(message)
        case .menuActionResult:
            handleMenuActionResult(message)
        case .pong:
            handlePong(message)
        case .qualityTestResult:
            handleQualityTestResult(message)
        case .qualityProbeResult:
            handleQualityProbeResult(message)
        default:
            break
        }
    }
}
