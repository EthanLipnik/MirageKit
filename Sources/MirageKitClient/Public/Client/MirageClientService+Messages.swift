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
    func registerControlMessageHandlers() {
        controlMessageHandlers = [
            .helloResponse: { [weak self] in await self?.handleHelloResponse($0) },
            .windowList: { [weak self] in self?.handleWindowList($0) },
            .windowUpdate: { [weak self] in self?.handleWindowUpdate($0) },
            .streamStarted: { [weak self] in self?.handleStreamStarted($0) },
            .streamStopped: { [weak self] in self?.handleStreamStopped($0) },
            .streamMetricsUpdate: { [weak self] in self?.handleStreamMetricsUpdate($0) },
            .error: { [weak self] in self?.handleErrorMessage($0) },
            .disconnect: { [weak self] in await self?.handleDisconnectMessage($0) },
            .cursorUpdate: { [weak self] in self?.handleCursorUpdate($0) },
            .cursorPositionUpdate: { [weak self] in self?.handleCursorPositionUpdate($0) },
            .contentBoundsUpdate: { [weak self] in self?.handleContentBoundsUpdate($0) },
            .sessionStateUpdate: { [weak self] in self?.handleSessionStateUpdate($0) },
            .unlockResponse: { [weak self] in self?.handleUnlockResponse($0) },
            .loginDisplayReady: { [weak self] in self?.handleLoginDisplayReady($0) },
            .loginDisplayStopped: { [weak self] in self?.handleLoginDisplayStopped($0) },
            .desktopStreamStarted: { [weak self] in self?.handleDesktopStreamStarted($0) },
            .desktopStreamStopped: { [weak self] in self?.handleDesktopStreamStopped($0) },
            .appList: { [weak self] in self?.handleAppList($0) },
            .appStreamStarted: { [weak self] in self?.handleAppStreamStarted($0) },
            .windowAddedToStream: { [weak self] in self?.handleWindowAddedToStream($0) },
            .windowCooldownStarted: { [weak self] in self?.handleWindowCooldownStarted($0) },
            .windowCooldownCancelled: { [weak self] in self?.handleWindowCooldownCancelled($0) },
            .returnToAppSelection: { [weak self] in self?.handleReturnToAppSelection($0) },
            .appTerminated: { [weak self] in self?.handleAppTerminated($0) },
            .menuBarUpdate: { [weak self] in self?.handleMenuBarUpdate($0) },
            .menuActionResult: { [weak self] in self?.handleMenuActionResult($0) },
            .pong: { [weak self] in self?.handlePong($0) },
            .qualityTestResult: { [weak self] in self?.handleQualityTestResult($0) },
            .qualityProbeResult: { [weak self] in self?.handleQualityProbeResult($0) },
            .audioStreamStarted: { [weak self] in self?.handleAudioStreamStarted($0) },
            .audioStreamStopped: { [weak self] in self?.handleAudioStreamStopped($0) }
        ]
    }

    func routeControlMessage(_ message: ControlMessage) async {
        guard let handler = controlMessageHandlers[message.type] else {
            MirageLogger.client("Unhandled control message: \(message.type)")
            return
        }
        await handler(message)
    }
}
