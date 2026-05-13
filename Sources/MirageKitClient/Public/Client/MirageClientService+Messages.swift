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
            .windowList: .message { [weak self] in self?.handleWindowList($0) },
            .windowUpdate: .message { [weak self] in self?.handleWindowUpdate($0) },
            .streamStarted: .message { [weak self] in await self?.handleStreamStarted($0) },
            .streamMetricsUpdate: .message { [weak self] in self?.handleStreamMetricsUpdate($0) },
            .keyframeRecoveryAck: .message { [weak self] in self?.handleKeyframeRecoveryAck($0) },
            .error: .message { [weak self] in self?.handleErrorMessage($0) },
            .disconnect: .message { [weak self] in await self?.handleDisconnectMessage($0) },
            .cursorUpdate: .message { [weak self] in self?.handleCursorUpdate($0) },
            .cursorPositionUpdate: .message { [weak self] in self?.handleCursorPositionUpdate($0) },
            .sessionStateUpdate: .message { [weak self] in self?.handleSessionStateUpdate($0) },
            .desktopStreamStarted: .message { [weak self] in await self?.handleDesktopStreamStarted($0) },
            .desktopStreamStopped: .message { [weak self] in self?.handleDesktopStreamStopped($0) },
            .desktopStreamFailed: .message { [weak self] in self?.handleDesktopStreamFailed($0) },
            .appListProgress: .message { [weak self] in await self?.handleAppListProgress($0) },
            .appListComplete: .message { [weak self] in self?.handleAppListComplete($0) },
            .appStreamStarted: .message { [weak self] in self?.handleAppStreamStarted($0) },
            .appAtlasMediaUpdate: .message { [weak self] in await self?.handleAppAtlasMediaUpdate($0) },
            .appWindowInventory: .message { [weak self] in self?.handleAppWindowInventory($0) },
            .appWindowCloseBlockedAlert: .message { [weak self] in self?.handleAppWindowCloseBlockedAlert($0) },
            .appWindowCloseAlertActionResult: .message { [weak self] in self?.handleAppWindowCloseAlertActionResult($0) },
            .windowAddedToStream: .message { [weak self] in self?.handleWindowAddedToStream($0) },
            .windowRemovedFromStream: .message { [weak self] in self?.handleWindowRemovedFromStream($0) },
            .appWindowSwapResult: .message { [weak self] in self?.handleAppWindowSwapResult($0) },
            .windowStreamFailed: .message { [weak self] in self?.handleWindowStreamFailed($0) },
            .appTerminated: .message { [weak self] in self?.handleAppTerminated($0) },
            .streamPolicyUpdate: .message { [weak self] in self?.handleStreamPolicyUpdate($0) },
            .menuBarUpdate: .message { [weak self] in self?.handleMenuBarUpdate($0) },
            .remoteClientStreamOptionsCommand: .message { [weak self] in
                self?.handleRemoteClientStreamOptionsCommand($0)
            },
            .hostHardwareIcon: .message { [weak self] in self?.handleHostHardwareIcon($0) },
            .hostWallpaper: .message { [weak self] in self?.handleHostWallpaper($0) },
            .hostSupportLogArchive: .message { [weak self] in self?.handleHostSupportLogArchive($0) },
            .ping: .empty { [weak self] in
                self?.queueControlMessageBestEffort(ControlMessage(type: .pong))
            },
            .pong: .empty { [weak self] in
                guard let self else { return }
                completePingRequest(
                    expectedRequestID: pingRequestID,
                    result: .success(())
                )
            },
            .qualityTestResult: .message { [weak self] in self?.handleQualityTestBenchmark($0) },
            .qualityTestStageComplete: .message { [weak self] in self?.handleQualityTestStageCompletion($0) },
            .audioStreamStarted: .message { [weak self] in self?.handleAudioStreamStarted($0) },
            .audioStreamStopped: .message { [weak self] in self?.handleAudioStreamStopped($0) },
            .hostSoftwareUpdateStatus: .message { [weak self] in self?.handleHostSoftwareUpdateStatus($0) },
            .hostSoftwareUpdateInstallResult: .message { [weak self] in self?.handleHostSoftwareUpdateInstallResult($0) },
            .hostApplicationRestartResult: .message { [weak self] in self?.handleHostApplicationRestartResult($0) },
            .transportRefreshRequest: .message { [weak self] in self?.handleTransportRefreshRequest($0) },
            .sharedClipboardStatus: .message { [weak self] in self?.handleSharedClipboardStatus($0) },
            .sharedClipboardUpdate: .message { [weak self] in self?.handleSharedClipboardUpdate($0) },
            .customStreamStarted: .message { [weak self] in await self?.handleCustomStreamStarted($0) },
            .customStreamStopped: .message { [weak self] in await self?.handleCustomStreamStopped($0) },
            .customStreamFailed: .message { [weak self] in self?.handleCustomStreamFailed($0) },
        ]
    }

    func routeControlMessage(_ message: ControlMessage) async {
        guard let handler = controlMessageHandlers[message.type] else {
            MirageLogger.client("Unhandled control message: \(message.type)")
            return
        }
        switch handler {
        case let .message(handle):
            await handle(message)
        case let .empty(handle):
            await handle()
        }
    }
}
