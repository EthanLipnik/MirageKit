//
//  MirageHostService+Clients.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client disconnection and cleanup.
//

import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    public func disconnectClient(_ client: MirageConnectedClient) async {
        // Clear any stuck modifier state from this client's session
        inputController.clearAllModifiers()

        if activeAudioClientID == client.id {
            await stopAudioStreaming(reason: "Client disconnected")
        }

        audioConnectionByClientID.removeValue(forKey: client.id)

        // Stop all window streams for this client and minimize their windows
        for stream in activeStreams where stream.client.id == client.id {
            await stopStream(stream, minimizeWindow: true)
        }

        // Stop desktop stream if owned by this client
        // This prevents host from continuing to encode/send frames after client disconnects
        if let desktopClient = desktopStreamClientContext, desktopClient.client.id == client.id {
            MirageLogger.host("Stopping desktop stream for disconnected client: \(client.name)")
            await stopDesktopStream(reason: .clientRequested)
        }

        // Remove client
        var removedConnectionID: ObjectIdentifier?
        if let key = clientsByConnection.first(where: { $0.value.client.id == client.id })?.key {
            clientsByConnection.removeValue(forKey: key)
            removedConnectionID = key
        }

        if let removedConnectionID, singleClientConnectionID == removedConnectionID {
            singleClientConnectionID = nil
        }

        connectedClients.removeAll { $0.id == client.id }

        stopSessionRefreshLoopIfIdle()
        if clientsByConnection.isEmpty {
            singleClientConnectionID = nil
            await stopLoginDisplayStream(newState: sessionState)
            await cleanupSharedVirtualDisplayIfIdle()
        }
    }

    private func cleanupSharedVirtualDisplayIfIdle() async {
        guard activeStreams.isEmpty, loginDisplayContext == nil, desktopStreamContext == nil else { return }

        let stats = await SharedVirtualDisplayManager.shared.getStatistics()
        guard stats.hasDisplay else { return }

        MirageLogger.host("No active streams or clients; destroying shared virtual display")
        await SharedVirtualDisplayManager.shared.destroyAllAndClear()
    }
}
#endif
