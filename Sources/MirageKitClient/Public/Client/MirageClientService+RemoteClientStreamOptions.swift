//
//  MirageClientService+RemoteClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Mirrors client-owned stream-option state back to the connected host UI.
    func sendRemoteClientStreamOptionsStateUpdate(
        displayMode: MirageStreamOptionsDisplayMode,
        statusOverlayEnabled: Bool,
        desktopCursorLockAvailable: Bool,
        desktopCursorLockMode: MirageDesktopCursorLockMode
    ) {
        let update = RemoteClientStreamOptionsStateMessage(
            displayMode: displayMode,
            statusOverlayEnabled: statusOverlayEnabled,
            desktopCursorLockAvailable: desktopCursorLockAvailable,
            desktopCursorLockMode: desktopCursorLockMode
        )
        _ = sendControlMessageBestEffort(.remoteClientStreamOptionsState, content: update)
    }
}

@MainActor
extension MirageClientService {
    func handleRemoteClientStreamOptionsCommand(_ message: ControlMessage) {
        do {
            let command = try message.decode(RemoteClientStreamOptionsCommandMessage.self)

            if let displayMode = command.displayMode {
                onRemoteClientStreamOptionsDisplayModeCommand?(displayMode)
            }

            if let statusOverlayEnabled = command.statusOverlayEnabled {
                onRemoteClientStreamStatusOverlayCommand?(statusOverlayEnabled)
            }

            if let desktopCursorPresentation = command.desktopCursorPresentation {
                onRemoteClientDesktopCursorPresentationCommand?(desktopCursorPresentation)
            }

            if let desktopCursorLockMode = command.desktopCursorLockMode {
                onRemoteClientDesktopCursorLockModeCommand?(desktopCursorLockMode)
            }

            if let stopAppBundleIdentifier = command.stopAppBundleIdentifier,
               !stopAppBundleIdentifier.isEmpty {
                onRemoteClientStopAppStreamCommand?(stopAppBundleIdentifier)
            }

            if command.stopDesktopStream == true {
                onRemoteClientStopDesktopStreamCommand?()
            }
        } catch {
            MirageLogger.error(
                .client,
                error: error,
                message: "Failed to decode remote client stream options command: "
            )
        }
    }
}
