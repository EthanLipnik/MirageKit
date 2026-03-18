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
    nonisolated func isFatalConnectionError(_ error: Error) -> Bool {
        let fatalPosixCodes: Set<POSIXErrorCode> = [.ECANCELED, .ECONNRESET, .ENOTCONN, .EPIPE]
        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return fatalPosixCodes.contains(code)
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return fatalPosixCodes.contains(code)
        }
        if nsError.domain == "NWError", nsError.code == -65554 || nsError.code == -65555 {
            return true
        }
        return false
    }

    func handleControlChannelSendFailure(
        client: MirageConnectedClient,
        error: Error,
        operation: String
    ) async {
        if isFatalConnectionError(error) || LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
            MirageLogger.host(
                "\(operation) skipped because the control channel closed for \(client.name): \(error.localizedDescription)"
            )
        } else {
            MirageLogger.error(.host, error: error, message: "\(operation) failed: ")
        }

        guard clientsByID[client.id] != nil else { return }
        await disconnectClient(client)
    }

    func makeSessionHelloRequest() throws -> LoomSessionHelloRequest {
        LoomSessionHelloRequest(
            deviceID: hostID,
            deviceName: serviceName,
            deviceType: .mac,
            advertisement: advertisedPeerAdvertisement
        )
    }

    func handleIncomingSession(_ session: LoomAuthenticatedSession) async {
        guard let context = await session.context else {
            await session.cancel()
            return
        }

        let peerIdentity = context.peerIdentity
        let sessionID = session.id
        let remoteEndpoint = await session.remoteEndpoint
        let pathSnapshot = await session.pathSnapshot
        let origin: MirageHostConnectionOrigin = inferOrigin(
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        )

        await preemptExistingClientIfSuperseded(by: peerIdentity)

        // Release stale slot reservation left by an incomplete cleanup.
        // Safe because preemptExistingClientIfSuperseded already handled any
        // same-device reconnect, so a non-nil singleClientSessionID with no
        // tracked clients is genuinely orphaned.
        if singleClientSessionID != nil, clientsBySessionID.isEmpty, connectedClients.isEmpty {
            MirageLogger.host("Releasing stale client slot reservation \(singleClientSessionID!)")
            singleClientSessionID = nil
        }

        guard reserveSingleClientSlot(for: sessionID) else {
            MirageLogger.host(
                "Connection rejected: slot reserved=\(singleClientSessionID?.uuidString ?? "nil"), "
                + "tracked=\(clientsBySessionID.count), connected=\(connectedClients.count)"
            )
            let controlChannel = try? await MirageControlChannel.accept(from: session)
            if let controlChannel {
                let response = MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: serviceName,
                    selectedFeatures: [],
                    dataPort: currentDataPort(),
                    mediaEncryptionEnabled: false,
                    udpRegistrationToken: Data(),
                    rejectionReason: .hostBusy
                )
                try? await controlChannel.send(.sessionBootstrapResponse, content: response)
                await controlChannel.cancel()
            } else {
                await session.cancel()
            }
            return
        }

        defer {
            if clientsBySessionID[sessionID] == nil {
                releaseSingleClientSlot(for: sessionID)
            }
        }

        do {
            let connectionAccepted = await withCheckedContinuation { continuation in
                if let delegate {
                    delegate.hostService(
                        self,
                        shouldAcceptConnectionFrom: peerIdentity.deviceInfo,
                        origin: origin,
                        completion: { accepted in
                            continuation.resume(returning: accepted)
                        }
                    )
                } else {
                    continuation.resume(returning: true)
                }
            }

            guard connectionAccepted else {
                MirageLogger.host("Connection from \(peerIdentity.name) rejected by delegate (origin=\(origin))")
                let controlChannel = try? await MirageControlChannel.accept(from: session)
                if let controlChannel {
                    let rejection = MirageSessionBootstrapResponse(
                        accepted: false,
                        hostID: hostID,
                        hostName: Host.current().localizedName ?? "Mac",
                        selectedFeatures: [],
                        dataPort: currentDataPort(),
                        mediaEncryptionEnabled: false,
                        udpRegistrationToken: Data(),
                        rejectionReason: .unauthorized
                    )
                    try? await controlChannel.send(.sessionBootstrapResponse, content: rejection)
                    await controlChannel.cancel()
                } else {
                    await session.cancel()
                }
                return
            }

            let controlChannel = try await MirageControlChannel.accept(from: session)
            MirageLogger.host("Accepted Mirage control channel from \(peerIdentity.name) origin=\(origin)")
            let bootstrap = try await receiveBootstrapRequest(from: controlChannel)
            MirageLogger.host("Received Mirage bootstrap request from \(peerIdentity.name)")
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
                await controlChannel.cancel()
                return
            }

            let client = MirageConnectedClient(
                id: peerIdentity.deviceID,
                name: peerIdentity.name,
                deviceType: peerIdentity.deviceType,
                connectedAt: .now,
                identityKeyID: peerIdentity.identityKeyID,
                autoTrustGranted: context.trustEvaluation.shouldShowAutoTrustNotice,
                connectionOrigin: origin
            )

            let clientContext = ClientContext(
                sessionID: sessionID,
                client: client,
                negotiatedFeatures: responseResult.response.selectedFeatures,
                controlChannel: controlChannel,
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot,
                udpConnection: nil
            )
            connectedClients.append(client)
            clientsBySessionID[sessionID] = clientContext
            clientsByID[client.id] = clientContext
            peerIdentityByClientID[client.id] = peerIdentity
            mediaSecurityByClientID[client.id] = responseResult.mediaSecurity
            mediaEncryptionEnabledByClientID[client.id] = responseResult.response.mediaEncryptionEnabled
            singleClientSessionID = sessionID

            await activateDeferredAudioIfNeeded(clientID: client.id)
            startReceivingFromClient(clientContext: clientContext)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to establish Mirage Loom control session: ")
            await session.cancel()
        }
    }

    private func receiveBootstrapRequest(
        from controlChannel: MirageControlChannel
    ) async throws -> MirageSessionBootstrapRequest {
        var buffer = Data()

        for await chunk in controlChannel.incomingBytes {
            guard !chunk.isEmpty else { continue }
            buffer.append(chunk)

            switch ControlMessage.deserialize(from: buffer) {
            case let .success(message, _):
                guard message.type == .sessionBootstrapRequest else {
                    throw MirageError.protocolError("Expected Mirage session bootstrap request")
                }
                return try message.decode(MirageSessionBootstrapRequest.self)
            case .needMoreData:
                continue
            case let .invalidFrame(reason):
                throw MirageError.protocolError("Invalid control frame: \(reason)")
            }
        }

        throw MirageError.protocolError("Control stream closed before session bootstrap request")
    }

    private func inferOrigin(
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) -> MirageHostConnectionOrigin {
        ClientContext.isPeerToPeerConnection(
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        ) ? .local : .remote
    }

    private func makeBootstrapResponse(
        for request: MirageSessionBootstrapRequest,
        peerIdentity: LoomPeerIdentity,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?,
        autoTrustGranted: Bool
    ) async throws -> (response: MirageSessionBootstrapResponse, mediaSecurity: MirageMediaSecurityContext?) {
        let hostName = Host.current().localizedName ?? "Mac"

        guard request.protocolVersion == Int(MirageKit.protocolVersion) else {
            let triggerResult = await handleProtocolMismatchUpdateRequestIfNeeded(
                request: request,
                peerIdentity: peerIdentity
            )
            return (
                MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: hostName,
                    selectedFeatures: [],
                    dataPort: currentDataPort(),
                    mediaEncryptionEnabled: false,
                    udpRegistrationToken: Data(),
                    rejectionReason: .protocolVersionMismatch,
                    protocolMismatchHostVersion: Int(MirageKit.protocolVersion),
                    protocolMismatchClientVersion: request.protocolVersion,
                    protocolMismatchUpdateTriggerAccepted: triggerResult?.accepted,
                    protocolMismatchUpdateTriggerMessage: triggerResult?.message
                ),
                nil
            )
        }

        let selectedFeatures = request.requestedFeatures.intersection(mirageSupportedFeatures)
        let requiredFeatures: MirageFeatureSet = [.udpRegistrationAuthV1, .encryptedMediaV1]
        guard selectedFeatures.contains(requiredFeatures) else {
            return (
                MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: hostName,
                    selectedFeatures: [],
                    dataPort: currentDataPort(),
                    mediaEncryptionEnabled: false,
                    udpRegistrationToken: Data(),
                    rejectionReason: .protocolFeaturesMismatch
                ),
                nil
            )
        }

        guard let identityManager else {
            throw MirageError.protocolError("Cannot bootstrap session without identity manager")
        }
        guard let clientPublicKey = peerIdentity.identityPublicKey,
              let clientKeyID = peerIdentity.identityKeyID else {
            throw MirageError.protocolError("Authenticated Loom session is missing client identity metadata")
        }

        let hostIdentity = try identityManager.currentIdentity()
        let mediaEncryptionEnabled = resolveAcceptedSessionMediaEncryptionPolicy(
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        )
        let udpRegistrationToken = MirageMediaSecurity.makeRegistrationToken()
        let mediaSecurity = try MirageMediaSecurity.deriveContextForAuthenticatedSession(
            identityManager: identityManager,
            peerPublicKey: clientPublicKey,
            hostID: hostID,
            clientID: peerIdentity.deviceID,
            hostKeyID: hostIdentity.keyID,
            clientKeyID: clientKeyID,
            udpRegistrationToken: udpRegistrationToken
        )

        let response = MirageSessionBootstrapResponse(
            accepted: true,
            hostID: hostID,
            hostName: hostName,
            selectedFeatures: selectedFeatures,
            dataPort: currentDataPort(),
            mediaEncryptionEnabled: mediaEncryptionEnabled,
            udpRegistrationToken: udpRegistrationToken,
            autoTrustGranted: autoTrustGranted,
            remoteAccessAllowed: delegate?.hostService(self, remoteAccessAllowedFor: peerIdentity.deviceInfo) ?? false
        )
        return (response, mediaSecurity)
    }

    private func currentDataPort() -> UInt16 {
        if case let .advertising(_, port) = state { return port }
        return 0
    }

    func mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: Bool) -> Bool {
        guard isPeerToPeer else { return true }
        return networkConfig.requireEncryptedMediaOnLocalNetwork
    }

    func resolveAcceptedSessionMediaEncryptionPolicy(
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) -> Bool {
        mediaEncryptionEnabledForAcceptedSession(
            isPeerToPeer: ClientContext.isPeerToPeerConnection(
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot
            )
        )
    }

    func mediaSecurityContextForMediaPayload(clientID: UUID) -> MirageMediaSecurityContext? {
        guard mediaEncryptionEnabledByClientID[clientID] == true else { return nil }
        return mediaSecurityByClientID[clientID]
    }

    func handleProtocolMismatchUpdateRequestIfNeeded(
        request: MirageSessionBootstrapRequest,
        peerIdentity: LoomPeerIdentity
    ) async -> (accepted: Bool, message: String)? {
        guard request.requestHostUpdateOnProtocolMismatch == true else { return nil }
        guard let softwareUpdateController else {
            return (false, "Host update service unavailable.")
        }

        let isAuthorized = await softwareUpdateController.hostService(
            self,
            shouldAuthorizeSoftwareUpdateRequestFrom: peerIdentity,
            trigger: .protocolMismatch
        )
        guard isAuthorized else {
            return (false, "Remote update request denied for this device.")
        }

        let result = await softwareUpdateController.hostService(
            self,
            performSoftwareUpdateInstallFor: peerIdentity,
            trigger: .protocolMismatch
        )
        return (result.accepted, result.message)
    }

    func shouldPreemptExistingClient(
        _ existingClient: MirageConnectedClient,
        for incomingPeerIdentity: LoomPeerIdentity
    ) -> Bool {
        if existingClient.id == incomingPeerIdentity.deviceID { return true }
        guard let existingIdentityKeyID = existingClient.identityKeyID,
              let incomingIdentityKeyID = incomingPeerIdentity.identityKeyID else {
            return false
        }
        return existingIdentityKeyID == incomingIdentityKeyID
    }

    func preemptExistingClientIfSuperseded(by incomingPeerIdentity: LoomPeerIdentity) async {
        guard let existingClient = clientsBySessionID.values.first?.client else { return }
        guard shouldPreemptExistingClient(existingClient, for: incomingPeerIdentity) else { return }

        MirageLogger.host(
            "Preempting existing client \(existingClient.name) for reconnect from \(incomingPeerIdentity.name)"
        )
        await disconnectClient(existingClient)
    }

    func reserveSingleClientSlot(for sessionID: UUID) -> Bool {
        if let reservedID = singleClientSessionID, reservedID != sessionID { return false }

        if let existingSessionID = clientsBySessionID.keys.first, existingSessionID != sessionID {
            singleClientSessionID = existingSessionID
            return false
        }

        singleClientSessionID = sessionID
        return true
    }

    func releaseSingleClientSlot(for sessionID: UUID) {
        if singleClientSessionID == sessionID {
            singleClientSessionID = nil
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
