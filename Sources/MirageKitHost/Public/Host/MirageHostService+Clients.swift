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
        if disconnectingClientIDs.contains(client.id) { return }
        disconnectingClientIDs.insert(client.id)
        defer { disconnectingClientIDs.remove(client.id) }

        MirageInstrumentation.record(.hostClientDisconnected)

        // Clear any stuck modifier state from this client's session
        inputController.clearAllModifiers()

        if pendingAppListRequest?.clientID == client.id {
            pendingAppListRequest = nil
            appListRequestTask?.cancel()
            appListRequestTask = nil
            await appStreamManager.cancelAppListScans()
        }
        clearPendingAppWindowCloseAlertTokens(forClientID: client.id)

        // Fail closed before asynchronous teardown work so queued handlers no longer
        // treat this client as active.
        var removedConnectionID: ObjectIdentifier?
        if let key = clientsByConnection.first(where: { $0.value.client.id == client.id })?.key {
            clientsByConnection.removeValue(forKey: key)
            removedConnectionID = key
            stopReceiveLoop(connectionID: key)
        }
        clientsByID.removeValue(forKey: client.id)
        peerIdentityByClientID.removeValue(forKey: client.id)
        mediaSecurityByClientID.removeValue(forKey: client.id)
        mediaEncryptionEnabledByClientID.removeValue(forKey: client.id)
        sharedClipboardStatusByClientID.removeValue(forKey: client.id)
        qualityTestConnectionsByClientID.removeValue(forKey: client.id)
        qualityTestBenchmarkIDsByClientID.removeValue(forKey: client.id)
        if let task = qualityTestTasksByClientID.removeValue(forKey: client.id) {
            task.cancel()
        }

        if let removedConnectionID, singleClientConnectionID == removedConnectionID { singleClientConnectionID = nil }
        removeControlWorker(clientID: client.id)
        connectedClients.removeAll { $0.id == client.id }

        // End app sessions immediately so window-monitor callbacks cannot spawn new streams
        // while disconnect teardown is in progress.
        await appStreamManager.endSessionsForClient(client.id)

        // Stop all window streams for this client and minimize their windows.
        // Use a drain loop instead of a snapshot so concurrently started streams
        // are also torn down before disconnect completes.
        while let stream = activeStreams.first(where: { $0.client.id == client.id }) {
            await stopStream(stream, minimizeWindow: true, updateAppSession: false)
        }

        // Stop desktop stream if owned by this client.
        if let desktopClient = desktopStreamClientContext, desktopClient.client.id == client.id {
            MirageLogger.host("Stopping desktop stream for disconnected client: \(client.name)")
            await stopDesktopStream(reason: .clientRequested)
        }

        await stopAudioForDisconnectedClient(client.id)

        let removedTransportConnections = transportRegistry.unregisterAllConnections(clientID: client.id)
        for connection in removedTransportConnections {
            connection.cancel()
        }

        let hasConnectedClients = !connectedClients.isEmpty
        stopSessionRefreshLoopIfIdle()
        if !hasConnectedClients {
            // Force local output unmute when the host no longer has any active clients.
            hostAudioMuteController.setMuted(false)
            singleClientConnectionID = nil
            await stopLoginDisplayStream(newState: sessionState)
            await cleanupSharedVirtualDisplayIfIdle()
            await forceDisableLightsOut(reason: "last client disconnected")
        }

        await restoreStageManagerAfterAppStreamingIfNeeded()
        syncSharedClipboardState(reason: "client_disconnected")
    }

    private func cleanupSharedVirtualDisplayIfIdle() async {
        guard activeStreams.isEmpty, loginDisplayContext == nil, desktopStreamContext == nil else { return }

        let stats = await SharedVirtualDisplayManager.shared.getStatistics()
        guard stats.hasDisplay || stats.dedicatedDisplayCount > 0 else { return }

        MirageLogger.host("No active streams or clients; destroying managed virtual displays")
        await SharedVirtualDisplayManager.shared.destroyAllAndClear()
    }
}
#endif
