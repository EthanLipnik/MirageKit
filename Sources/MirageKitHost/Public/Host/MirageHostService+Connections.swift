//
//  MirageHostService+Connections.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  TCP connection lifecycle and hello handshake.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    private struct ReceivedHello {
        let deviceInfo: MirageDeviceInfo
        let negotiation: MirageProtocolNegotiation
        let requestNonce: String
        let identity: MirageIdentityEnvelope
        let pendingControlData: Data
    }

    private enum ApprovalOutcome {
        case accepted
        case rejected
        case connectionClosed
        case timedOut
    }

    private actor ApprovalDecisionGate {
        private var didResume = false
        private var tasks: [Task<Void, Never>] = []
        private let box: SafeContinuationBox<ApprovalOutcome>

        init(box: SafeContinuationBox<ApprovalOutcome>) {
            self.box = box
        }

        func register(tasks: [Task<Void, Never>]) {
            guard !didResume else {
                for task in tasks { task.cancel() }
                return
            }
            self.tasks = tasks
        }

        func finish(_ outcome: ApprovalOutcome) {
            guard !didResume else { return }
            didResume = true
            let tasksToCancel = tasks
            tasks = []
            for task in tasksToCancel { task.cancel() }
            box.resume(returning: outcome)
        }
    }

    /// Check if an error indicates a fatal, unrecoverable connection state.
    func isFatalConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let fatalPosixCodes = [54, 57, 32, 104]
        if nsError.domain == NSPOSIXErrorDomain, fatalPosixCodes.contains(nsError.code) { return true }
        if nsError.domain == "NWError", nsError.code == -65554 || nsError.code == -65555 { return true }
        return false
    }

    func handleNewConnection(_ connection: NWConnection) async {
        MirageLogger.host("New client connection")

        connection.start(queue: .global(qos: .userInitiated))

        let isReady = await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            connection.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume(returning: true)
                case .cancelled,
                     .failed:
                    box.resume(returning: false)
                default:
                    break
                }
            }
        }

        guard isReady else {
            MirageLogger.host("Client connection failed")
            return
        }

        let endpointDescription: String = switch connection.endpoint {
        case let .hostPort(host, port):
            "\(host):\(port)"
        case let .service(name, _, _, _):
            name
        default:
            connection.endpoint.debugDescription
        }

        MirageLogger.host("Waiting for hello message from \(endpointDescription)...")

        guard let hello = await receiveHelloMessage(from: connection, endpoint: endpointDescription) else {
            MirageLogger.host("Closing connection without valid hello from \(endpointDescription)")
            connection.cancel()
            return
        }
        let deviceInfo = hello.deviceInfo

        let connectionID = ObjectIdentifier(connection)

        guard reserveSingleClientSlot(for: connectionID) else {
            if let activeClient = clientsByConnection.values.first?.client {
                MirageLogger.host(
                    "Rejecting \(deviceInfo.name); host already has active client \(activeClient.name)"
                )
            } else {
                MirageLogger.host("Rejecting \(deviceInfo.name); host already has a pending client")
            }
            sendHelloResponse(
                accepted: false,
                to: connection,
                dataPort: currentDataPort(),
                negotiation: hello.negotiation,
                deviceInfo: hello.deviceInfo,
                requestNonce: hello.requestNonce,
                cancelAfterSend: true
            )
            return
        }

        defer {
            if clientsByConnection[connectionID] == nil { releaseSingleClientSlot(for: connectionID) }
        }

        let approvalOutcome = await awaitApprovalDecision(for: deviceInfo, connection: connection)
        connection.stateUpdateHandler = nil

        switch approvalOutcome {
        case .accepted:
            break
        case .rejected:
            MirageLogger.host("Connection rejected")
            connection.cancel()
            return
        case .connectionClosed:
            MirageLogger.host("Connection closed while awaiting approval")
            connection.cancel()
            return
        case .timedOut:
            MirageLogger.host("Connection approval timed out after \(Int(connectionApprovalTimeoutSeconds))s")
            connection.cancel()
            return
        }

        MirageLogger.host("Connection approved, sending hello response...")
        let responseResult = sendHelloResponse(
            accepted: true,
            to: connection,
            dataPort: currentDataPort(),
            negotiation: hello.negotiation,
            deviceInfo: hello.deviceInfo,
            requestNonce: hello.requestNonce,
            cancelAfterSend: false
        )
        guard responseResult.sent else {
            MirageLogger.error(.host, "Failed to send accepted hello response to \(deviceInfo.name)")
            connection.cancel()
            return
        }

        let client = MirageConnectedClient(
            id: deviceInfo.id,
            name: deviceInfo.name,
            deviceType: deviceInfo.deviceType,
            connectedAt: Date(),
            identityKeyID: deviceInfo.identityKeyID
        )

        let clientContext = ClientContext(
            client: client,
            tcpConnection: connection,
            udpConnection: nil
        )
        if let mediaSecurity = responseResult.mediaSecurity {
            mediaSecurityByClientID[client.id] = mediaSecurity
            MirageLogger.host(
                "Media security established for \(client.name) " +
                    "(tokenBytes=\(mediaSecurity.udpRegistrationToken.count), keyBytes=\(mediaSecurity.sessionKey.count))"
            )
        } else {
            MirageLogger.error(.host, "Missing media security context for accepted client \(client.name)")
            connection.cancel()
            return
        }
        clientsByConnection[ObjectIdentifier(connection)] = clientContext
        clientsByID[client.id] = clientContext
        audioConfigurationByClientID[client.id] = .default

        connectedClients.append(client)
        delegate?.hostService(self, didConnectClient: client)

        startSessionRefreshLoopIfNeeded()
        await refreshSessionStateIfNeeded()
        await sendSessionState(to: clientContext)

        if sessionState == .active { await sendWindowList(to: clientContext) } else {
            await startLoginDisplayStreamIfNeeded()
            MirageLogger.host("Session is \(sessionState), client will show unlock form")
        }

        startReceivingFromClient(
            connection: connection,
            client: client,
            initialBuffer: hello.pendingControlData
        )
    }

    /// Receive hello message from a connecting client.
    private func receiveHelloMessage(from connection: NWConnection, endpoint: String) async -> ReceivedHello? {
        let result: (
            Data?,
            NWConnection.ContentContext?,
            Bool,
            NWError?
        ) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
                continuation.resume(returning: (data, context, isComplete, error))
            }
        }

        let (data, _, _, error) = result

        if let error {
            MirageLogger.error(.host, "Error receiving hello: \(error)")
            return nil
        }

        guard let data, !data.isEmpty else {
            MirageLogger.host("No data received for hello")
            return nil
        }

        guard let (message, consumed) = ControlMessage.deserialize(from: data) else {
            MirageLogger.host("Failed to deserialize hello message")
            return nil
        }

        guard message.type == .hello else {
            MirageLogger.host("Expected hello message, got \(message.type)")
            return nil
        }

        do {
            let hello = try message.decode(HelloMessage.self)
            guard hello.protocolVersion == Int(MirageKit.protocolVersion) else {
                MirageLogger.host(
                    "Rejected hello from \(hello.deviceName): legacy protocol field \(hello.protocolVersion) unsupported"
                )
                return nil
            }
            guard hello.negotiation.protocolVersion == Int(MirageKit.protocolVersion) else {
                MirageLogger.host(
                    "Rejected hello from \(hello.deviceName): protocol \(hello.negotiation.protocolVersion) unsupported"
                )
                return nil
            }
            guard hello.negotiation.supportedFeatures.contains(.identityAuthV2) else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): missing identityAuthV2 support")
                return nil
            }
            guard hello.negotiation.supportedFeatures.contains(.udpRegistrationAuthV1) else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): missing udpRegistrationAuthV1 support")
                return nil
            }
            guard hello.negotiation.supportedFeatures.contains(.encryptedMediaV1) else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): missing encryptedMediaV1 support")
                return nil
            }
            let identity = hello.identity
            guard identity.keyID == MirageIdentityManager.keyID(for: identity.publicKey) else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): invalid identity key ID")
                return nil
            }
            let replayValid = await handshakeReplayProtector.validate(
                timestampMs: identity.timestampMs,
                nonce: identity.nonce
            )
            guard replayValid else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): replay protection failed")
                return nil
            }
            let signedPayload = try MirageIdentitySigning.helloPayload(
                deviceID: hello.deviceID,
                deviceName: hello.deviceName,
                deviceType: hello.deviceType,
                protocolVersion: hello.protocolVersion,
                capabilities: hello.capabilities,
                negotiation: hello.negotiation,
                iCloudUserID: hello.iCloudUserID,
                keyID: identity.keyID,
                publicKey: identity.publicKey,
                timestampMs: identity.timestampMs,
                nonce: identity.nonce
            )
            guard MirageIdentityManager.verify(
                signature: identity.signature,
                payload: signedPayload,
                publicKey: identity.publicKey
            ) else {
                MirageLogger.host("Rejected hello from \(hello.deviceName): signature verification failed")
                return nil
            }
            let selectedFeatures = hello.negotiation.supportedFeatures.intersection(mirageSupportedFeatures)
            MirageLogger.host("Received hello from \(hello.deviceName) (\(hello.deviceType.displayName))")
            let pendingControlData = consumed < data.count ? Data(data.dropFirst(consumed)) : Data()
            if !pendingControlData.isEmpty {
                MirageLogger.host(
                    "Buffered \(pendingControlData.count) control bytes that arrived with hello from \(hello.deviceName)"
                )
            }

            return ReceivedHello(
                deviceInfo: MirageDeviceInfo(
                    id: hello.deviceID,
                    name: hello.deviceName,
                    deviceType: hello.deviceType,
                    endpoint: endpoint,
                    iCloudUserID: hello.iCloudUserID,
                    identityKeyID: identity.keyID,
                    identityPublicKey: identity.publicKey,
                    isIdentityAuthenticated: true
                ),
                negotiation: MirageProtocolNegotiation(
                    protocolVersion: Int(MirageKit.protocolVersion),
                    supportedFeatures: mirageSupportedFeatures,
                    selectedFeatures: selectedFeatures
                ),
                requestNonce: identity.nonce,
                identity: identity,
                pendingControlData: pendingControlData
            )
        } catch {
            MirageLogger.error(.host, "Failed to decode hello: \(error)")
            return nil
        }
    }

    /// Evaluates trust using the provider and falls back to delegate approval if needed.
    private func evaluateTrustAndApproval(for deviceInfo: MirageDeviceInfo) async -> Bool {
        // If a trust provider is set, consult it first
        if let trustProvider {
            let peerIdentity = MiragePeerIdentity(
                deviceID: deviceInfo.id,
                name: deviceInfo.name,
                deviceType: deviceInfo.deviceType,
                iCloudUserID: deviceInfo.iCloudUserID,
                identityKeyID: deviceInfo.identityKeyID,
                identityPublicKey: deviceInfo.identityPublicKey,
                isIdentityAuthenticated: deviceInfo.isIdentityAuthenticated,
                endpoint: deviceInfo.endpoint
            )

            let decision = await trustProvider.evaluateTrust(for: peerIdentity)

            switch decision {
            case .trusted:
                MirageLogger.host("Connection auto-approved by trust provider for \(deviceInfo.name)")
                return true

            case .denied:
                MirageLogger.host("Connection denied by trust provider for \(deviceInfo.name)")
                return false

            case .requiresApproval:
                MirageLogger.host("Trust provider requires approval for \(deviceInfo.name)")
                // Fall through to delegate

            case let .unavailable(reason):
                MirageLogger
                    .host("Trust provider unavailable (\(reason)), falling back to delegate for \(deviceInfo.name)")
                // Fall through to delegate
            }
        }

        // Fall back to delegate-based approval
        MirageLogger.host("Requesting approval for \(deviceInfo.name) (\(deviceInfo.deviceType.displayName))...")

        return await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            if let delegate {
                delegate.hostService(self, shouldAcceptConnectionFrom: deviceInfo) { accepted in
                    box.resume(returning: accepted)
                }
            } else {
                // No delegate and no trust provider decision - accept by default
                box.resume(returning: true)
            }
        }
    }

    private func awaitApprovalDecision(
        for deviceInfo: MirageDeviceInfo,
        connection: NWConnection
    ) async -> ApprovalOutcome {
        await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<ApprovalOutcome>(continuation)
            let gate = ApprovalDecisionGate(box: box)

            let approvalTask = Task { @MainActor in
                let approved = await self.evaluateTrustAndApproval(for: deviceInfo)
                await gate.finish(approved ? .accepted : .rejected)
            }

            let closureTask = Task { @MainActor in
                await self.waitForConnectionClosure(connection)
                await gate.finish(.connectionClosed)
            }

            let timeoutTask = Task {
                let timeout = Duration.seconds(Int(self.connectionApprovalTimeoutSeconds))
                try? await Task.sleep(for: timeout)
                await gate.finish(.timedOut)
            }

            Task {
                await gate.register(tasks: [approvalTask, closureTask, timeoutTask])
            }
        }
    }

    private func waitForConnectionClosure(_ connection: NWConnection) async {
        let stream = AsyncStream<Void> { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed,
                     .cancelled:
                    continuation.yield(())
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { _ in
                connection.stateUpdateHandler = nil
            }
        }

        for await _ in stream {
            break
        }
    }

    private func currentDataPort() -> UInt16 {
        if case let .advertising(_, port) = state { return port }
        return 0
    }

    func reserveSingleClientSlot(for connectionID: ObjectIdentifier) -> Bool {
        if let reservedID = singleClientConnectionID, reservedID != connectionID { return false }

        if let existingConnectionID = clientsByConnection.keys.first, existingConnectionID != connectionID {
            singleClientConnectionID = existingConnectionID
            return false
        }

        singleClientConnectionID = connectionID
        return true
    }

    func releaseSingleClientSlot(for connectionID: ObjectIdentifier) {
        if singleClientConnectionID == connectionID { singleClientConnectionID = nil }
    }

    @discardableResult
    private func sendHelloResponse(
        accepted: Bool,
        to connection: NWConnection,
        dataPort: UInt16,
        negotiation: MirageProtocolNegotiation,
        deviceInfo: MirageDeviceInfo,
        requestNonce: String,
        cancelAfterSend: Bool
    )
    -> (sent: Bool, mediaSecurity: MirageMediaSecurityContext?) {
        do {
            let hostName = Host.current().localizedName ?? "Mac"
            guard let identityManager else {
                MirageLogger.error(.host, "Cannot send hello response without identity manager")
                connection.cancel()
                return (false, nil)
            }
            let identity = try identityManager.currentIdentity()
            let timestampMs = MirageIdentitySigning.currentTimestampMs()
            let nonce = UUID().uuidString.lowercased()
            let mediaEncryptionEnabled = accepted
            let udpRegistrationToken = accepted ? MirageMediaSecurity.makeRegistrationToken() : Data()
            let mediaSecurityContext: MirageMediaSecurityContext?
            if accepted {
                guard let clientPublicKey = deviceInfo.identityPublicKey,
                      let clientKeyID = deviceInfo.identityKeyID else {
                    MirageLogger.error(.host, "Cannot derive media key without client identity metadata")
                    return (false, nil)
                }
                do {
                    mediaSecurityContext = try MirageMediaSecurity.deriveContext(
                        identityManager: identityManager,
                        peerPublicKey: clientPublicKey,
                        hostID: hostID,
                        clientID: deviceInfo.id,
                        hostKeyID: identity.keyID,
                        clientKeyID: clientKeyID,
                        hostNonce: nonce,
                        clientNonce: requestNonce,
                        udpRegistrationToken: udpRegistrationToken
                    )
                } catch {
                    MirageLogger.error(.host, "Failed to derive media security context: \(error)")
                    return (false, nil)
                }
            } else {
                mediaSecurityContext = nil
            }
            let payload = try MirageIdentitySigning.helloResponsePayload(
                accepted: accepted,
                hostID: hostID,
                hostName: hostName,
                requiresAuth: false,
                dataPort: dataPort,
                negotiation: negotiation,
                requestNonce: requestNonce,
                mediaEncryptionEnabled: mediaEncryptionEnabled,
                udpRegistrationToken: udpRegistrationToken,
                keyID: identity.keyID,
                publicKey: identity.publicKey,
                timestampMs: timestampMs,
                nonce: nonce
            )
            let signature = try identityManager.sign(payload)
            let response = HelloResponseMessage(
                accepted: accepted,
                hostID: hostID,
                hostName: hostName,
                requiresAuth: false,
                dataPort: dataPort,
                negotiation: negotiation,
                requestNonce: requestNonce,
                mediaEncryptionEnabled: mediaEncryptionEnabled,
                udpRegistrationToken: udpRegistrationToken,
                identity: MirageIdentityEnvelope(
                    keyID: identity.keyID,
                    publicKey: identity.publicKey,
                    timestampMs: timestampMs,
                    nonce: nonce,
                    signature: signature
                )
            )
            let message = try ControlMessage(type: .helloResponse, content: response)
            let data = message.serialize()

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MirageLogger.error(.host, "Failed to send hello response: \(error)")
                    if accepted { connection.cancel() }
                } else if accepted {
                    MirageLogger.host(
                        "Sent hello response with dataPort \(dataPort), mediaEncryption=\(mediaEncryptionEnabled)"
                    )
                } else {
                    MirageLogger.host("Sent rejection hello response")
                }

                if cancelAfterSend { connection.cancel() }
            })
            return (true, mediaSecurityContext)
        } catch {
            MirageLogger.error(.host, "Failed to create hello response: \(error)")
            if cancelAfterSend { connection.cancel() }
            return (false, nil)
        }
    }
}
#endif
