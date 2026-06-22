//
//  MirageHostService+RemoteClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Sends a display-mode preference change to the connected client.
    func setRemoteClientStreamOptionsDisplayMode(_ displayMode: MirageWire.MirageStreamOptionsDisplayMode) async {
        remoteClientStreamOptionsDisplayMode = displayMode
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(displayMode: displayMode)
        await sendRemoteClientStreamOptionsCommand(command, operation: "stream options display mode update")
    }

    /// Sends a status-overlay preference change to the connected client.
    func setRemoteClientStreamStatusOverlayEnabled(_ isEnabled: Bool) async {
        remoteClientStreamStatusOverlayEnabled = isEnabled
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(statusOverlayEnabled: isEnabled)
        await sendRemoteClientStreamOptionsCommand(command, operation: "status overlay update")
    }

    /// Sends an active desktop cursor presentation change to the connected client.
    func applyRemoteClientDesktopCursorPresentation(_ presentation: MirageWire.MirageDesktopCursorPresentation) async {
        guard desktopStreamID != nil else { return }
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(
            desktopCursorPresentation: presentation
        )
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop cursor update")
    }

    /// Sends an active desktop cursor lock mode change to the connected client.
    func setRemoteClientDesktopCursorLockMode(_ mode: MirageWire.MirageDesktopCursorLockMode) async {
        remoteClientDesktopCursorLockMode = mode
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(desktopCursorLockMode: mode)
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop cursor lock mode update")
    }

    /// Requests that the client stop the active app stream for the bundle identifier.
    func requestRemoteClientStopAppStream(bundleIdentifier: String) async {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(
            stopAppBundleIdentifier: bundleIdentifier
        )
        await sendRemoteClientStreamOptionsCommand(command, operation: "app stream stop")
    }

    /// Requests that the client stop its active desktop stream.
    func requestRemoteClientStopDesktopStream() async {
        guard desktopStreamID != nil else { return }
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(stopDesktopStream: true)
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop stream stop")
    }
}

extension MirageHostService {
    /// Handles the client's current stream-options state snapshot.
    func handleRemoteClientStreamOptionsState(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let state = try message.decode(MirageWire.RemoteClientStreamOptionsStateMessage.self)
            remoteClientStreamOptionsDisplayMode = state.displayMode
            remoteClientStreamStatusOverlayEnabled = state.statusOverlayEnabled
            remoteClientDesktopCursorLockAvailable = state.desktopCursorLockAvailable
            remoteClientDesktopCursorLockMode = state.desktopCursorLockMode
            MirageLogger.host(
                "Client \(clientContext.client.name) synced stream options: "
                    + "displayMode=\(state.displayMode.rawValue) "
                    + "statusOverlay=\(state.statusOverlayEnabled) "
                    + "cursorLockAvailable=\(state.desktopCursorLockAvailable) "
                    + "cursorLockMode=\(state.desktopCursorLockMode.rawValue)"
            )
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to decode remoteClientStreamOptionsState: "
            )
        }
    }

    /// Sends a remote-client stream-options command over the active control channel.
    private func sendRemoteClientStreamOptionsCommand(
        _ command: MirageWire.RemoteClientStreamOptionsCommandMessage,
        operation: String
    ) async {
        guard let clientContext = desktopStreamClientContext ?? clientsBySessionID.values.first else { return }

        do {
            try await clientContext.send(.remoteClientStreamOptionsCommand, content: command)
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Remote client \(operation)",
                sessionID: clientContext.sessionID
            )
        }
    }
}
#endif
