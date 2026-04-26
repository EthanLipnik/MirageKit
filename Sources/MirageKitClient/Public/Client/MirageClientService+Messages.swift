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
            .windowList: { [weak self] in self?.handleWindowList($0) },
            .windowUpdate: { [weak self] in self?.handleWindowUpdate($0) },
            .streamStarted: { [weak self] in await self?.handleStreamStarted($0) },
            .streamStopped: { [weak self] in self?.handleStreamStopped($0) },
            .streamMetricsUpdate: { [weak self] in self?.handleStreamMetricsUpdate($0) },
            .error: { [weak self] in self?.handleErrorMessage($0) },
            .disconnect: { [weak self] in await self?.handleDisconnectMessage($0) },
            .cursorUpdate: { [weak self] in self?.handleCursorUpdate($0) },
            .cursorPositionUpdate: { [weak self] in self?.handleCursorPositionUpdate($0) },
            .sessionStateUpdate: { [weak self] in self?.handleSessionStateUpdate($0) },
            .desktopStreamStarted: { [weak self] in await self?.handleDesktopStreamStarted($0) },
            .desktopStreamStopped: { [weak self] in self?.handleDesktopStreamStopped($0) },
            .desktopStreamFailed: { [weak self] in self?.handleDesktopStreamFailed($0) },
            .appListProgress: { [weak self] in self?.handleAppListProgress($0) },
            .appList: { [weak self] in self?.handleAppList($0) },
            .appStreamStarted: { [weak self] in self?.handleAppStreamStarted($0) },
            .appWindowInventory: { [weak self] in self?.handleAppWindowInventory($0) },
            .appWindowCloseBlockedAlert: { [weak self] in self?.handleAppWindowCloseBlockedAlert($0) },
            .appWindowCloseAlertActionResult: { [weak self] in self?.handleAppWindowCloseAlertActionResult($0) },
            .windowAddedToStream: { [weak self] in self?.handleWindowAddedToStream($0) },
            .windowRemovedFromStream: { [weak self] in self?.handleWindowRemovedFromStream($0) },
            .appWindowSwapResult: { [weak self] in self?.handleAppWindowSwapResult($0) },
            .windowStreamFailed: { [weak self] in self?.handleWindowStreamFailed($0) },
            .appTerminated: { [weak self] in self?.handleAppTerminated($0) },
            .streamPolicyUpdate: { [weak self] in self?.handleStreamPolicyUpdate($0) },
            .menuBarUpdate: { [weak self] in self?.handleMenuBarUpdate($0) },
            .menuActionResult: { [weak self] in self?.handleMenuActionResult($0) },
            .remoteClientStreamOptionsCommand: { [weak self] in
                self?.handleRemoteClientStreamOptionsCommand($0)
            },
            .hostHardwareIcon: { [weak self] in self?.handleHostHardwareIcon($0) },
            .hostWallpaper: { [weak self] in self?.handleHostWallpaper($0) },
            .hostSupportLogArchive: { [weak self] in self?.handleHostSupportLogArchive($0) },
            .appIconUpdate: { [weak self] in self?.handleAppIconUpdate($0) },
            .appIconStreamComplete: { [weak self] in self?.handleAppIconStreamComplete($0) },
            .ping: { [weak self] in self?.handlePing($0) },
            .pong: { [weak self] in self?.handlePong($0) },
            .qualityTestResult: { [weak self] in self?.handleQualityTestBenchmark($0) },
            .qualityTestStageComplete: { [weak self] in self?.handleQualityTestStageCompletion($0) },
            .audioStreamStarted: { [weak self] in self?.handleAudioStreamStarted($0) },
            .audioStreamStopped: { [weak self] in self?.handleAudioStreamStopped($0) },
            .hostSoftwareUpdateStatus: { [weak self] in self?.handleHostSoftwareUpdateStatus($0) },
            .hostSoftwareUpdateInstallResult: { [weak self] in self?.handleHostSoftwareUpdateInstallResult($0) },
            .hostApplicationRestartResult: { [weak self] in self?.handleHostApplicationRestartResult($0) },
            .transportRefreshRequest: { [weak self] in self?.handleTransportRefreshRequest($0) },
            .sharedClipboardStatus: { [weak self] in self?.handleSharedClipboardStatus($0) },
            .sharedClipboardUpdate: { [weak self] in self?.handleSharedClipboardUpdate($0) }
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
