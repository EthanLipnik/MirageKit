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
    private func awaitBootstrapStep<T: Sendable>(
        timeout: Duration,
        peerName: String,
        phase: String,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MirageError.protocolError("Timed out waiting for \(phase) from \(peerName)")
            }

            let result = try await group.next() ?? {
                throw MirageError.protocolError("Bootstrap step ended unexpectedly")
            }()
            group.cancelAll()
            return result
        }
    }

    nonisolated func isExpectedBootstrapConnectionClosure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case let .protocolError(message):
                return message == "Authenticated Loom session closed before Mirage control stream opened" ||
                    message == "Control stream closed before session bootstrap request"
            case let .connectionFailed(underlyingError):
                return isExpectedBootstrapConnectionClosure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isExpectedBootstrapConnectionClosure(underlyingError)
            default:
                break
            }
        }

        if let failure = error as? LoomConnectionFailure {
            switch failure.reason {
            case .cancelled, .closed:
                return true
            case .timedOut, .transportLoss, .connectionRefused, .addressUnavailable, .other:
                break
            }
        }

        return false
    }

    nonisolated func isFatalConnectionError(_ error: Error) -> Bool {
        if let mirageError = error as? MirageError {
            switch mirageError {
            case .authenticationFailed, .connectionFailed, .timeout:
                return true
            default:
                break
            }
        }

        let fatalPosixCodes: Set<POSIXErrorCode> = [
            .ECANCELED, .ECONNRESET, .ENOTCONN, .EPIPE,
            .EADDRNOTAVAIL, // 49 — can't assign requested address (transport gone)
            .ECONNREFUSED, // 61 — connection refused (peer closed/crashed)
        ]
        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return fatalPosixCodes.contains(code)
            default:
                break
            }
        }

        let nsError = error as NSError

        // LoomError(0) = cancelled, LoomError(3) = authenticationFailed
        // Both indicate the session is dead — treat as fatal.
        if nsError.domain == "Loom.LoomError" {
            let fatalLoomCodes: Set<Int> = [0, 3]
            return fatalLoomCodes.contains(nsError.code)
        }

        // NWError.connectionFailed wraps the underlying POSIX code in its
        // description but doesn't expose it as .posix().  Extract it from
        // the NSError bridge.
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return fatalPosixCodes.contains(code)
        }
        // NWError domain uses negative codes; the underlying POSIX code is
        // embedded in the userInfo or the code itself for connectionFailed.
        if nsError.domain == "NWError" {
            if nsError.code == -65554 || nsError.code == -65555 {
                return true
            }
            // connectionFailed wraps a POSIX code as a positive value in
            // the underlying error chain.
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
                return fatalPosixCodes.contains(code)
            }
        }
        // Last resort: check the string representation for known POSIX codes
        let desc = String(describing: error)
        if desc.contains("POSIXErrorCode(rawValue: 89)") ||
           desc.contains("POSIXErrorCode(rawValue: 61)") ||
           desc.contains("POSIXErrorCode(rawValue: 57)") ||
           desc.contains("POSIXErrorCode(rawValue: 54)") ||
           desc.contains("POSIXErrorCode(rawValue: 49)") ||
           desc.contains("POSIXErrorCode(rawValue: 32)") {
            return true
        }
        return false
    }

    nonisolated func isExpectedLifecycleControlSendFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "Loom.LoomError", nsError.code == 0 {
            return true
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError):
                return isExpectedLifecycleControlSendFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isExpectedLifecycleControlSendFailure(underlyingError)
            default:
                break
            }
        }

        if let failure = error as? LoomConnectionFailure {
            switch failure.reason {
            case .cancelled, .closed:
                return true
            case .timedOut, .transportLoss, .connectionRefused, .addressUnavailable, .other:
                break
            }
        }

        return false
    }

    func handleControlChannelSendFailure(
        client: MirageConnectedClient,
        error: Error,
        operation: String,
        sessionID: UUID? = nil
    ) async {
        if let sessionID,
           findClientContext(sessionID: sessionID)?.client.id != client.id {
            return
        }

        // After the first send failure for a client, subsequent sends will
        // also fail while disconnectClient() is in flight.  Log only the
        // first failure as a Sentry event to avoid flooding diagnostics
        // with one error per queued app icon / metadata send.
        let isFirstFailure = controlChannelSendFailureReported.insert(client.id).inserted

        if isFatalConnectionError(error) ||
            isExpectedLifecycleControlSendFailure(error) ||
            LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
            if isFirstFailure {
                MirageLogger.host(
                    "\(operation) skipped because the control channel closed for \(client.name): \(error.localizedDescription)"
                )
            }
        } else if isFirstFailure {
            MirageLogger.error(.host, error: error, message: "\(operation) failed: ")
        }

        guard clientsByID[client.id] != nil else { return }
        await disconnectClient(client, sessionID: sessionID)
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

        delegate?.hostService(self, didDiscoverPeerWithAdvertisement: context.peerAdvertisement)

        let peerIdentity = context.peerIdentity
        let sessionID = session.id
        let remoteEndpoint = await session.remoteEndpoint
        let pathSnapshot = await session.pathSnapshot
        let origin: MirageHostConnectionOrigin = inferOrigin(
            peerAdvertisement: context.peerAdvertisement,
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        )
        MirageLogger.host(
            "Incoming authenticated session trustDecision=\(String(describing: context.trustEvaluation.decision)) "
                + "autoTrustNotice=\(context.trustEvaluation.shouldShowAutoTrustNotice) "
                + "deviceID=\(peerIdentity.deviceID.uuidString.lowercased()) "
                + "keyID=\(peerIdentity.identityKeyID?.lowercased() ?? "nil") "
                + "name=\(peerIdentity.name) origin=\(origin)"
        )

        if await hostSoftwareUpdateInstallInProgress(for: peerIdentity) {
            MirageLogger.host("Connection rejected while host software update install is in progress")
            await rejectIncomingSession(session, reason: .hostBusy)
            return
        }

        await waitForDisconnectCompletionIfNeeded(for: peerIdentity)
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
            await rejectIncomingSession(session, reason: .hostBusy)
            return
        }

        defer {
            if clientsBySessionID[sessionID] == nil {
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
            }

            guard connectionAccepted else {
                MirageLogger.host("Connection from \(peerIdentity.name) rejected by delegate (origin=\(origin))")
                let controlChannel = try? await MirageControlChannel.accept(from: session)
                if let controlChannel {
                    let rejection = MirageSessionBootstrapResponse(
                        accepted: false,
                        hostID: hostID,
                        hostName: serviceName,
                        selectedFeatures: [],
                        mediaEncryptionEnabled: false,
                        udpRegistrationToken: Data(),
                        rejectionReason: .unauthorized
                    )
                    try? await controlChannel.send(.sessionBootstrapResponse, content: rejection)
                    try? await controlChannel.closeStream()
                } else {
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
                try await self.receiveBootstrapRequest(from: controlChannel)
            }
            MirageLogger.host("Received Mirage bootstrap request from \(peerIdentity.name)")
            let responseResult = try await makeBootstrapResponse(
                for: bootstrap,
                peerIdentity: peerIdentity,
                peerAdvertisement: context.peerAdvertisement,
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot,
                autoTrustGranted: context.trustEvaluation.shouldShowAutoTrustNotice
            )
            try await controlChannel.send(.sessionBootstrapResponse, content: responseResult.response)
            MirageLogger.host(
                "Sent Mirage bootstrap response to \(peerIdentity.name) accepted=\(responseResult.response.accepted)"
            )

            guard responseResult.response.accepted else {
                try? await controlChannel.closeStream()
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
                negotiatedFeatures: responseResult.response.selectedFeatures,
                controlChannel: controlChannel,
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot
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
            startClientLivenessMonitorIfNeeded()
            delegate?.hostService(self, didConnectClient: client)
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
        peerAdvertisement: LoomPeerAdvertisement,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) -> MirageHostConnectionOrigin {
        if let metadataValue = peerAdvertisement.metadata[mirageConnectionOriginMetadataKey],
           let origin = MirageHostConnectionOrigin(metadataValue: metadataValue) {
            return origin
        }
        return ClientContext.isPeerToPeerConnection(
            remoteEndpoint: remoteEndpoint,
            pathSnapshot: pathSnapshot
        ) ? MirageHostConnectionOrigin.local : MirageHostConnectionOrigin.remote
    }

    private func makeBootstrapResponse(
        for request: MirageSessionBootstrapRequest,
        peerIdentity: LoomPeerIdentity,
        peerAdvertisement: LoomPeerAdvertisement,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?,
        autoTrustGranted: Bool
    ) async throws -> (response: MirageSessionBootstrapResponse, mediaSecurity: MirageMediaSecurityContext?) {
        let hostName = serviceName

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
            peerAdvertisement: peerAdvertisement,
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
            mediaEncryptionEnabled: mediaEncryptionEnabled,
            udpRegistrationToken: udpRegistrationToken,
            autoTrustGranted: autoTrustGranted,
            remoteAccessAllowed: delegate?.hostService(self, remoteAccessAllowedFor: peerIdentity.deviceInfo) ?? false
        )
        return (response, mediaSecurity)
    }

    func mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: Bool) -> Bool {
        guard isPeerToPeer else { return true }
        return networkConfig.requireEncryptedMediaOnLocalNetwork
    }

    func resolveAcceptedSessionMediaEncryptionPolicy(
        peerAdvertisement: LoomPeerAdvertisement,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?
    ) -> Bool {
        if let metadataValue = peerAdvertisement.metadata[mirageConnectionOriginMetadataKey],
           let origin = MirageHostConnectionOrigin(metadataValue: metadataValue) {
            return mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: origin == .local)
        }
        return mediaEncryptionEnabledForAcceptedSession(
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

    func hostSoftwareUpdateInstallInProgress(for peerIdentity: LoomPeerIdentity) async -> Bool {
        guard let softwareUpdateController else { return false }
        let status = await softwareUpdateController.hostService(
            self,
            softwareUpdateStatusFor: peerIdentity,
            forceRefresh: false
        )
        return status.isInstallInProgress
    }

    func rejectIncomingSession(
        _ session: LoomAuthenticatedSession,
        reason: MirageSessionBootstrapRejectionReason
    ) async {
        let controlChannel = try? await MirageControlChannel.accept(from: session)
        if let controlChannel {
            let response = MirageSessionBootstrapResponse(
                accepted: false,
                hostID: hostID,
                hostName: serviceName,
                selectedFeatures: [],
                mediaEncryptionEnabled: false,
                udpRegistrationToken: Data(),
                rejectionReason: reason
            )
            try? await controlChannel.send(.sessionBootstrapResponse, content: response)
            try? await controlChannel.closeStream()
        } else {
            await session.cancel()
        }
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

    func waitForDisconnectCompletionIfNeeded(
        for incomingPeerIdentity: LoomPeerIdentity,
        timeout: Duration = .seconds(5)
    ) async {
        guard shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) else { return }

        let deadline = ContinuousClock.now + timeout
        MirageLogger.host(
            "Waiting for disconnect teardown to finish before accepting reconnect from \(incomingPeerIdentity.name)"
        )

        while shouldWaitForDisconnectCompletion(for: incomingPeerIdentity) {
            if ContinuousClock.now >= deadline {
                MirageLogger.host(
                    "Timed out waiting for disconnect teardown before reconnect from \(incomingPeerIdentity.name)"
                )
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    private func shouldWaitForDisconnectCompletion(for incomingPeerIdentity: LoomPeerIdentity) -> Bool {
        if disconnectingClientIDs.contains(incomingPeerIdentity.deviceID) {
            return true
        }

        guard let existingClient = connectedClients.first(where: {
            shouldPreemptExistingClient($0, for: incomingPeerIdentity)
        }) else {
            return false
        }

        return disconnectingClientIDs.contains(existingClient.id)
    }

    func expireStaleSingleClientReservationIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard let reservedSessionID = singleClientSessionID,
              clientsBySessionID.isEmpty,
              connectedClients.isEmpty,
              disconnectingClientIDs.isEmpty,
              let reservationStartedAt = singleClientReservationStartedAt,
              now - reservationStartedAt >= connectionApprovalTimeoutSeconds else {
            return
        }

        MirageLogger.host(
            "Expiring stale client slot reservation \(reservedSessionID.uuidString) after \(now - reservationStartedAt)s"
        )
        singleClientSessionID = nil
    }

    func reserveSingleClientSlot(for sessionID: UUID) -> Bool {
        expireStaleSingleClientReservationIfNeeded()

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

private let mirageConnectionOriginMetadataKey = "mirage.connection-origin"

private extension MirageHostConnectionOrigin {
    init?(metadataValue: String) {
        self.init(rawValue: metadataValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
