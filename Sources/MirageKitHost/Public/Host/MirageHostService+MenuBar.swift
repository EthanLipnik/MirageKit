//
//  MirageHostService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import MirageKit

#if os(macOS)

extension MirageHostService {
    /// Handles a client request to invoke an item in a streamed app's menu bar.
    func handleMenuActionRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        do {
            let request = try message.decode(MenuActionRequestMessage.self)
            MirageLogger.log(.menuBar, "Client \(clientContext.client.name) requested menu action: \(request.actionPath)")

            guard let session = activeSessionByStreamID[request.streamID],
                  let app = session.window.application else {
                MirageLogger.log(.menuBar, "Menu action skipped for missing stream \(request.streamID)")
                return
            }

            let success = await menuBarMonitor.performMenuAction(pid: app.id, actionPath: request.actionPath)
            if !success {
                MirageLogger.log(.menuBar, "Failed to execute menu action for stream \(request.streamID)")
            }
        } catch {
            MirageLogger.error(.menuBar, error: error, message: "Failed to handle menu action request: ")
        }
    }

    /// Starts menu bar monitoring for an application stream.
    func startMenuBarMonitoring(streamID: StreamID, app: MirageApplication, clientContext: ClientContext) async {
        await menuBarMonitor.startMonitoring(
            streamID: streamID,
            pid: app.id,
            bundleIdentifier: app.bundleIdentifier ?? ""
        ) { [weak self] (menuBar: MirageMenuBar) in
            guard let self else { return }
            Task { @MainActor in
                await self.sendMenuBarUpdate(streamID: streamID, menuBar: menuBar, to: clientContext)
            }
        }
    }

    /// Sends the latest menu bar snapshot to a client.
    func sendMenuBarUpdate(streamID: StreamID, menuBar: MirageMenuBar, to clientContext: ClientContext) async {
        let update = MenuBarUpdateMessage(streamID: streamID, menuBar: menuBar)
        clientContext.queueBestEffort(.menuBarUpdate, content: update)
    }
}

#endif
