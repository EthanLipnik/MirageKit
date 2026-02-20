//
//  MirageHostService+Clients.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client disconnection and cleanup.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    public func disconnectClient(_ client: MirageConnectedClient) async {
        // Clear any stuck modifier state from this client's session
        inputController.clearAllModifiers()

        if pendingAppListRequest?.clientID == client.id {
            pendingAppListRequest = nil
            appListRequestTask?.cancel()
            appListRequestTask = nil
            await appStreamManager.cancelAppListScans()
        }

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

        await stopAudioForDisconnectedClient(client.id)

        // Remove client
        var removedConnectionID: ObjectIdentifier?
        if let key = clientsByConnection.first(where: { $0.value.client.id == client.id })?.key {
            clientsByConnection.removeValue(forKey: key)
            removedConnectionID = key
            stopReceiveLoop(connectionID: key)
        }
        clientsByID.removeValue(forKey: client.id)
        peerIdentityByClientID.removeValue(forKey: client.id)
        mediaSecurityByClientID.removeValue(forKey: client.id)
        qualityTestConnectionsByClientID.removeValue(forKey: client.id)
        qualityTestBenchmarkIDsByClientID.removeValue(forKey: client.id)
        if let task = qualityTestTasksByClientID.removeValue(forKey: client.id) {
            task.cancel()
        }

        if let removedConnectionID, singleClientConnectionID == removedConnectionID { singleClientConnectionID = nil }
        removeControlWorker(clientID: client.id)

        connectedClients.removeAll { $0.id == client.id }

        let removedTransportConnections = transportRegistry.unregisterAllConnections(clientID: client.id)
        for connection in removedTransportConnections {
            connection.cancel()
        }

        stopSessionRefreshLoopIfIdle()
        if clientsByConnection.isEmpty {
            // Force local output unmute when the host no longer has any active clients.
            hostAudioMuteController.setMuted(false)
            singleClientConnectionID = nil
            await stopLoginDisplayStream(newState: sessionState)
            await cleanupSharedVirtualDisplayIfIdle()
            lockHostIfNeeded()
        }

        await restoreStageManagerAfterAppStreamingIfNeeded()
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
