import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+RemoteClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//


@MainActor
public extension MirageClientService {
    /// Mirrors client-owned stream-option state back to the connected host UI.
    func sendRemoteClientStreamOptionsStateUpdate(
        displayMode: MirageWire.MirageStreamOptionsDisplayMode,
        statusOverlayEnabled: Bool,
        desktopCursorLockAvailable: Bool,
        desktopCursorLockMode: MirageWire.MirageDesktopCursorLockMode
    ) {
        let update = MirageWire.RemoteClientStreamOptionsStateMessage(
            displayMode: displayMode,
            statusOverlayEnabled: statusOverlayEnabled,
            desktopCursorLockAvailable: desktopCursorLockAvailable,
            desktopCursorLockMode: desktopCursorLockMode
        )
        queueControlMessageBestEffort(.remoteClientStreamOptionsState, content: update)
    }
}

@MainActor
extension MirageClientService {
    /// Decodes host-issued remote controls and fans them out to UI-owned command handlers.
    func handleRemoteClientStreamOptionsCommand(_ message: MirageWire.ControlMessage) {
        do {
            let command = try message.decode(MirageWire.RemoteClientStreamOptionsCommandMessage.self)

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
