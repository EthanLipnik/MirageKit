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
        defer {
            disconnectingClientIDs.remove(client.id)
            controlChannelSendFailureReported.remove(client.id)
        }

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
        var removedSessionID: UUID?
        if let key = clientsBySessionID.first(where: { $0.value.client.id == client.id })?.key {
            clientsBySessionID.removeValue(forKey: key)
            removedSessionID = key
            stopReceiveLoop(sessionID: key)
        }
        clientsByID.removeValue(forKey: client.id)
        peerIdentityByClientID.removeValue(forKey: client.id)
        mediaSecurityByClientID.removeValue(forKey: client.id)
        mediaEncryptionEnabledByClientID.removeValue(forKey: client.id)
        sharedClipboardStatusByClientID.removeValue(forKey: client.id)
        qualityTestBenchmarkIDsByClientID.removeValue(forKey: client.id)
        if let task = qualityTestTasksByClientID.removeValue(forKey: client.id) {
            task.cancel()
        }

        if let removedSessionID, singleClientSessionID == removedSessionID { singleClientSessionID = nil }
        removeControlWorker(clientID: client.id)
        connectedClients.removeAll { $0.id == client.id }

        // End app sessions immediately so window-monitor callbacks cannot spawn new streams
        // while disconnect teardown is in progress.
        await appStreamManager.endSessionsForClient(client.id)

        // Stop all window streams for this client. Skip minimization when Stage
        // Manager will be re-enabled — it will rearrange windows on its own.
        // Use a drain loop instead of a snapshot so concurrently started streams
        // are also torn down before disconnect completes.
        let minimizeOnDisconnect = !appStreamingStageManagerNeedsRestore
        while let stream = activeStreams.first(where: { $0.client.id == client.id }) {
            await stopStream(stream, minimizeWindow: minimizeOnDisconnect, updateAppSession: false)
        }

        // Stop desktop stream if owned by this client.
        if let desktopClient = desktopStreamClientContext, desktopClient.client.id == client.id {
            MirageLogger.host("Stopping desktop stream for disconnected client: \(client.name)")
            await stopDesktopStream(reason: .clientRequested)
        }

        await stopAudioForDisconnectedClient(client.id)

        transportRegistry.unregisterAllStreams(clientID: client.id)
        if let audioStream = loomAudioStreamsByClientID.removeValue(forKey: client.id) {
            Task { try? await audioStream.close() }
        }

        let hasConnectedClients = !connectedClients.isEmpty
        stopSessionRefreshLoopIfIdle()
        if !hasConnectedClients {
            // Force local output unmute when the host no longer has any active clients.
            hostAudioMuteController.setMuted(false)
            singleClientSessionID = nil
            await cleanupSharedVirtualDisplayIfIdle()
            await forceDisableLightsOut(reason: "last client disconnected")
        }

        await restoreStageManagerAfterAppStreamingIfNeeded()
        syncSharedClipboardState(reason: "client_disconnected")

        // Final lock attempt after all cleanup (including Stage Manager restore
        // and virtual display teardown) to avoid interference from Dock restart
        // or display reconfiguration.
        lockHostIfStreamingStopped()
    }

    private func cleanupSharedVirtualDisplayIfIdle() async {
        guard activeStreams.isEmpty, desktopStreamContext == nil else { return }

        let stats = await SharedVirtualDisplayManager.shared.getStatistics()
        guard stats.hasDisplay || stats.dedicatedDisplayCount > 0 else { return }

        MirageLogger.host("No active streams or clients; destroying managed virtual displays")
        await SharedVirtualDisplayManager.shared.destroyAllAndClear()
    }
}
#endif
