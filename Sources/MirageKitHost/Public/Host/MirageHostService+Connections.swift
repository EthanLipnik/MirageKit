//
//  MirageHostService+Connections.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Loom-authenticated control session lifecycle and Mirage bootstrap.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Creates the Loom hello payload advertised to authenticated peers.
    func makeSessionHelloRequest() throws -> LoomSessionHelloRequest {
        LoomSessionHelloRequest(
            deviceID: hostID,
            deviceName: serviceName,
            deviceType: .mac,
            advertisement: advertisedPeerAdvertisement
        )
    }

    /// Accepts and bootstraps an authenticated Loom session into a Mirage client context.
    func handleIncomingSession(_ session: LoomAuthenticatedSession) async {
        guard let context = await session.context else {
            await session.cancel()
            return
        }

        delegate?.didDiscoverPeer(advertisement: context.peerAdvertisement)

        let peerIdentity = context.peerIdentity
        let sessionID = session.id
        let remoteEndpoint = await session.remoteEndpoint
        let pathSnapshot = await session.pathSnapshot
        let origin: MirageHostConnectionOrigin = ClientContext.isPeerToPeerConnection(
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        ) ? .local : .remote
        MirageLogger.host(
            "Incoming authenticated session trustDecision=\(String(describing: context.trustEvaluation.decision)) "
                + "autoTrustNotice=\(context.trustEvaluation.shouldShowAutoTrustNotice) "
                + "deviceID=\(peerIdentity.deviceID.uuidString.lowercased()) "
                + "keyID=\(peerIdentity.identityKeyID?.lowercased() ?? "nil") "
                + "name=\(peerIdentity.name) origin=\(origin)"
        )

        if await hostSoftwareUpdateInstallInProgress() {
            MirageLogger.host("Connection rejected while host software update install is in progress")
            await rejectIncomingSession(session, reason: .hostUpdateInProgress)
            return
        }
        if softwareUpdateMaintenanceModeActive {
            MirageLogger.host("Connection rejected while host software update maintenance is advertised")
            await rejectIncomingSession(session, reason: .hostUpdateInProgress)
            return
        }

        await waitForDisconnectCompletionIfNeeded(for: peerIdentity)
        await preemptExistingClientIfSuperseded(by: peerIdentity)

        // Release stale slot reservation left by an incomplete cleanup.
        // Safe because preemptExistingClientIfSuperseded already handled any
        // same-device reconnect, so a non-nil singleClientSessionID with no
        // tracked clients is genuinely orphaned.
        if let staleSingleClientSessionID = singleClientSessionID,
           clientsBySessionID.isEmpty,
           connectedClients.isEmpty {
            MirageLogger.host("Releasing stale client slot reservation \(staleSingleClientSessionID)")
            singleClientSessionID = nil
        }

        var reservedSingleClientSlot = false
        if busyClientContext(forIncomingSessionID: sessionID) == nil {
            guard reserveSingleClientSlot(for: sessionID) else {
                MirageLogger.host(
                    "Connection rejected: slot reserved=\(singleClientSessionID?.uuidString ?? "nil"), "
                        + "tracked=\(clientsBySessionID.count), connected=\(connectedClients.count)"
                )
                await rejectIncomingSession(session, reason: .hostBusy)
                return
            }
            reservedSingleClientSlot = true
        }

        defer {
            if reservedSingleClientSlot, clientsBySessionID[sessionID] == nil {
                releaseSingleClientSlot(for: sessionID)
            }
        }

        do {
            let connectionAccepted = try await awaitBootstrapStep(
                timeout: .seconds(Int(connectionApprovalTimeoutSeconds.rounded(.up))),
                peerName: peerIdentity.name,
                phase: "connection approval"
            ) { [self] in
                await withCheckedContinuation { continuation in
                    if let delegate = self.delegate {
                        delegate.shouldAcceptConnection(
                            from: peerIdentity.deviceInfo,
                            origin: origin,
                            completion: { accepted in
                                continuation.resume(returning: accepted)
                            }
                        )
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            }

            guard connectionAccepted else {
                MirageLogger.host("Connection from \(peerIdentity.name) rejected by delegate (origin=\(origin))")
                do {
                    let controlChannel = try await MirageControlChannel.accept(from: session)
                    let rejection = makeRejectedBootstrapResponse(reason: .unauthorized)
                    do {
                        try await controlChannel.send(.sessionBootstrapResponse, content: rejection)
                    } catch {
                        MirageLogger.error(.host, error: error, message: "Failed to send unauthorized bootstrap rejection: ")
                    }
                    await closeBootstrapControlChannel(controlChannel, reason: "unauthorized rejection")
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to accept control channel for unauthorized rejection: ")
                    await session.cancel()
                }
                return
            }

            let controlChannel = try await awaitBootstrapStep(
                timeout: .seconds(10),
                peerName: peerIdentity.name,
                phase: "Mirage control channel"
            ) {
                try await MirageControlChannel.accept(from: session)
            }
            MirageLogger.host("Accepted Mirage control channel from \(peerIdentity.name) origin=\(origin)")
            let bootstrap = try await awaitBootstrapStep(
                timeout: .seconds(10),
                peerName: peerIdentity.name,
                phase: "Mirage bootstrap request"
            ) { [self] in
                try await receiveBootstrapRequest(from: controlChannel)
            }
            MirageLogger.host("Received Mirage bootstrap request from \(peerIdentity.name)")

            if let busyClientContext = busyClientContext(forIncomingSessionID: sessionID) {
                if let rejectionReason = busyHostTakeoverRejectionReason(
                    for: bootstrap,
                    trustEvaluation: context.trustEvaluation,
                    existingClient: busyClientContext.client,
                    incomingPeerIdentity: peerIdentity
                ) {
                    MirageLogger.host(
                        "Connection from \(peerIdentity.name) rejected while host is busy reason=\(rejectionReason.rawValue)"
                    )
                    let rejection = makeRejectedBootstrapResponse(reason: rejectionReason)
                    try await controlChannel.send(.sessionBootstrapResponse, content: rejection)
                    await closeBootstrapControlChannel(controlChannel, reason: "busy rejection")
                    return
                }

                MirageLogger.host(
                    "Authorizing busy-host takeover by trusted client \(peerIdentity.name); disconnecting \(busyClientContext.client.name)"
                )
                await disconnectClient(
                    busyClientContext.client,
                    sessionID: busyClientContext.sessionID,
                    notifyClient: true,
                    reason: .takenOver
                )
                delegate?.didDisconnectClient(busyClientContext.client)
            }

            if !reservedSingleClientSlot {
                guard reserveSingleClientSlot(for: sessionID) else {
                    MirageLogger.host(
                        "Connection rejected after takeover check: slot reserved=\(singleClientSessionID?.uuidString ?? "nil"), "
                            + "tracked=\(clientsBySessionID.count), connected=\(connectedClients.count)"
                    )
                    let rejection = makeRejectedBootstrapResponse(reason: .hostBusy)
                    try await controlChannel.send(.sessionBootstrapResponse, content: rejection)
                    await closeBootstrapControlChannel(controlChannel, reason: "slot reservation rejection")
                    return
                }
                reservedSingleClientSlot = true
            }

            let responseResult = try await makeBootstrapResponse(
                for: bootstrap,
                peerIdentity: peerIdentity,
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot,
                autoTrustGranted: context.trustEvaluation.shouldShowAutoTrustNotice
            )
            try await controlChannel.send(.sessionBootstrapResponse, content: responseResult.response)
            MirageLogger.host(
                "Sent Mirage bootstrap response to \(peerIdentity.name) accepted=\(responseResult.response.accepted)"
            )

            guard responseResult.response.accepted else {
                await closeBootstrapControlChannel(controlChannel, reason: "bootstrap rejection")
                return
            }

            let client = MirageConnectedClient(
                id: peerIdentity.deviceID,
                name: peerIdentity.name,
                deviceType: peerIdentity.deviceType,
                connectedAt: .now,
                identityKeyID: peerIdentity.identityKeyID,
                autoTrustGranted: context.trustEvaluation.shouldShowAutoTrustNotice,
                connectionOrigin: origin,
                peerAdvertisement: context.peerAdvertisement
            )

            let clientContext = ClientContext(
                sessionID: sessionID,
                client: client,
                controlChannel: controlChannel,
                pathSnapshot: pathSnapshot
            )
            connectedClients.append(client)
            clientsBySessionID[sessionID] = clientContext
            clientsByID[client.id] = clientContext
            peerIdentityByClientID[client.id] = peerIdentity
            mediaSecurityByClientID[client.id] = responseResult.mediaSecurity
            mediaEncryptionEnabledByClientID[client.id] = responseResult.response.mediaEncryptionEnabled
            singleClientSessionID = sessionID
            streamRegistry.registerInputSession(sessionID, clientID: client.id)

            await sendSessionState(to: clientContext)
            await activateDeferredAudioIfNeeded(clientID: client.id)
            startReceivingFromClient(clientContext: clientContext)
            startClientLivenessMonitorIfNeeded()
            delegate?.didConnectClient(client)
        } catch {
            if isExpectedBootstrapConnectionClosure(error) ||
                isFatalConnectionError(error) ||
                LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                MirageLogger.host("Mirage Loom control session closed during bootstrap: \(error.localizedDescription)")
            } else {
                MirageLogger.error(.host, error: error, message: "Failed to establish Mirage Loom control session: ")
            }
            await session.cancel()
        }
    }
}

private extension LoomPeerIdentity {
    var deviceInfo: LoomPeerDeviceInfo {
        LoomPeerDeviceInfo(
            id: deviceID,
            name: name,
            deviceType: deviceType,
            endpoint: endpoint.debugDescription,
            iCloudUserID: iCloudUserID,
            identityKeyID: identityKeyID,
            identityPublicKey: identityPublicKey,
            isIdentityAuthenticated: isIdentityAuthenticated
        )
    }
}
#endif
