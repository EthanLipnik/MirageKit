//
//  MirageHostService+RemoteClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Whether the connected client currently has an active desktop stream.
    var isDesktopStreamActive: Bool {
        desktopStreamID != nil
    }

    /// Whether the connected client currently exposes desktop cursor lock controls.
    var activeDesktopCursorLockAvailable: Bool {
        desktopStreamID != nil && remoteClientDesktopCursorLockAvailable
    }

    /// Client currently receiving the active desktop stream, if any.
    var activeDesktopStreamClient: MirageConnectedClient? {
        desktopStreamClientContext?.client
    }

    /// Sends a display-mode preference change to the connected client.
    func setRemoteClientStreamOptionsDisplayMode(_ displayMode: MirageStreamOptionsDisplayMode) async {
        remoteClientStreamOptionsDisplayMode = displayMode
        let command = RemoteClientStreamOptionsCommandMessage(displayMode: displayMode)
        await sendRemoteClientStreamOptionsCommand(command, operation: "stream options display mode update")
    }

    /// Sends a status-overlay preference change to the connected client.
    func setRemoteClientStreamStatusOverlayEnabled(_ isEnabled: Bool) async {
        remoteClientStreamStatusOverlayEnabled = isEnabled
        let command = RemoteClientStreamOptionsCommandMessage(statusOverlayEnabled: isEnabled)
        await sendRemoteClientStreamOptionsCommand(command, operation: "status overlay update")
    }

    /// Sends an active desktop cursor presentation change to the connected client.
    func applyRemoteClientDesktopCursorPresentation(_ presentation: MirageDesktopCursorPresentation) async {
        guard desktopStreamID != nil else { return }
        let command = RemoteClientStreamOptionsCommandMessage(
            desktopCursorPresentation: presentation
        )
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop cursor update")
    }

    /// Sends an active desktop cursor lock mode change to the connected client.
    func setRemoteClientDesktopCursorLockMode(_ mode: MirageDesktopCursorLockMode) async {
        remoteClientDesktopCursorLockMode = mode
        let command = RemoteClientStreamOptionsCommandMessage(desktopCursorLockMode: mode)
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop cursor lock mode update")
    }

    /// Requests that the client stop the active app stream for the bundle identifier.
    func requestRemoteClientStopAppStream(bundleIdentifier: String) async {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = RemoteClientStreamOptionsCommandMessage(
            stopAppBundleIdentifier: bundleIdentifier
        )
        await sendRemoteClientStreamOptionsCommand(command, operation: "app stream stop")
    }

    /// Requests that the client stop its active desktop stream.
    func requestRemoteClientStopDesktopStream() async {
        guard desktopStreamID != nil else { return }
        let command = RemoteClientStreamOptionsCommandMessage(stopDesktopStream: true)
        await sendRemoteClientStreamOptionsCommand(command, operation: "desktop stream stop")
    }
}

extension MirageHostService {
    func handleRemoteClientStreamOptionsState(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let state = try message.decode(RemoteClientStreamOptionsStateMessage.self)
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

    private func sendRemoteClientStreamOptionsCommand(
        _ command: RemoteClientStreamOptionsCommandMessage,
        operation: String
    ) async {
        guard let clientContext = remoteClientCommandContext() else { return }

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

    private func remoteClientCommandContext() -> ClientContext? {
        if let desktopStreamClientContext {
            return desktopStreamClientContext
        }

        return clientsBySessionID.values.first
    }
}
#endif
