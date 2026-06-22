//
//  MirageHostService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
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
#if os(macOS)

extension MirageHostService {
    /// Handles a client request to invoke an item in a streamed app's menu bar.
    func handleMenuActionRequest(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    )
    async {
        do {
            let request = try message.decode(MirageWire.MenuActionRequestMessage.self)
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
    func startMenuBarMonitoring(streamID: StreamID, app: MirageMedia.MirageApplication, clientContext: ClientContext) async {
        await menuBarMonitor.startMonitoring(
            streamID: streamID,
            pid: app.id,
            bundleIdentifier: app.bundleIdentifier ?? ""
        ) { [weak self] (menuBar: MirageWire.MirageMenuBar) in
            guard let self else { return }
            Task { @MainActor in
                await self.sendMenuBarUpdate(streamID: streamID, menuBar: menuBar, to: clientContext)
            }
        }
    }

    /// Sends the latest menu bar snapshot to a client.
    func sendMenuBarUpdate(streamID: StreamID, menuBar: MirageWire.MirageMenuBar, to clientContext: ClientContext) async {
        let update = MirageWire.MenuBarUpdateMessage(streamID: streamID, menuBar: menuBar)
        clientContext.queueBestEffort(.menuBarUpdate, content: update)
    }
}

#endif
