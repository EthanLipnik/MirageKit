//
//  MirageClientService+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client connection lifecycle and hello handshake.
//

import Foundation
import Network
import MirageKit

#if canImport(UIKit)
import UIKit.UIDevice
#endif

#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension MirageClientService {
    /// Determine current device type.
    private var currentDeviceType: DeviceType {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad { return .iPad } else {
            return .iPhone
        }
        #elseif os(visionOS)
        return .vision
        #else
        return .unknown
        #endif
    }

    func controlParameters(for transport: ControlTransport) -> NWParameters {
        switch transport {
        case .tcp:
            let parameters = NWParameters.tcp
            parameters.serviceClass = .interactiveVideo
            parameters.includePeerToPeer = networkConfig.enablePeerToPeer

            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }
            return parameters

        case .quic:
            let options = NWProtocolQUIC.Options(alpn: ["mirage-v2"])
            let parameters = NWParameters(quic: options)
            parameters.serviceClass = .interactiveVideo
            parameters.includePeerToPeer = networkConfig.enablePeerToPeer
            parameters.allowLocalEndpointReuse = true
            return parameters
        }
    }

    func makeHelloMessage(
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) throws -> (hello: HelloMessage, nonce: String) {
        let negotiation = MirageProtocolNegotiation.clientHello(
            protocolVersion: Int(Loom.protocolVersion),
            supportedFeatures: mirageSupportedFeatures
        )
        let resolvedIdentityManager = identityManager ?? LoomIdentityManager.shared
        let identity = try resolvedIdentityManager.currentIdentity()
        let advertisement = MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: currentDeviceType,
            identityKeyID: identity.keyID
        )
        let timestampMs = MirageIdentitySigning.currentTimestampMs()
        let nonce = UUID().uuidString.lowercased()
        let payload = try MirageIdentitySigning.helloPayload(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: currentDeviceType,
            protocolVersion: Int(Loom.protocolVersion),
            advertisement: advertisement,
            negotiation: negotiation,
            iCloudUserID: iCloudUserID,
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let signature = try resolvedIdentityManager.sign(payload)
        let hello = HelloMessage(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: currentDeviceType,
            protocolVersion: Int(Loom.protocolVersion),
            advertisement: advertisement,
            negotiation: negotiation,
            iCloudUserID: iCloudUserID,
            identity: MirageIdentityEnvelope(
                keyID: identity.keyID,
                publicKey: identity.publicKey,
                timestampMs: timestampMs,
                nonce: nonce,
                signature: signature
            ),
            requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
        )
        return (hello, nonce)
    }

    /// Send hello message with device info to host.
    private func sendHelloMessage(
        connection: NWConnection,
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) async throws {
        do {
            let helloRequest = try makeHelloMessage(
                requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
            )
            pendingHelloNonce = helloRequest.nonce
            MirageInstrumentation.record(.clientHelloSent)
            let message = try ControlMessage(type: .hello, content: helloRequest.hello)
            let data = message.serialize()
            MirageLogger.client("Sending hello: \(deviceName) (\(currentDeviceType.displayName))")

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let continuationBox = ContinuationBox<Void>(continuation)
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuationBox.resume(throwing: error)
                    } else {
                        continuationBox.resume()
                    }
                })
            }

            MirageLogger.client("Hello sent successfully")
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to send hello message: ")
            throw error
        }
    }

    func awaitHelloHandshake(
        on connection: NWConnection,
        provisionalHost: LoomPeer
    ) async throws {
        connectionState = .handshaking(host: provisionalHost.name)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuationBox = ContinuationBox<Void>(continuation)
            helloHandshakeContinuation = continuationBox

            Task { @MainActor [weak self] in
                guard let self else {
                    continuationBox.resume(throwing: CancellationError())
                    return
                }

                do {
                    try await self.sendHelloMessage(connection: connection)
                    self.startManualApprovalWaitTimer()
                    self.startReceiving(on: connection)
                } catch {
                    if self.helloHandshakeContinuation === continuationBox {
                        self.helloHandshakeContinuation = nil
                    }
                    continuationBox.resume(throwing: error)
                }
            }
        }
    }

    /// Connect to a discovered host.
    public func connect(
        to host: LoomPeer,
        controlTransport: ControlTransport = .tcp
    )
    async throws {
        guard connectionState.canConnect else { throw MirageError.protocolError("Already connected or connecting") }

        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name) using \(controlTransport)...")
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        await handshakeReplayProtector.reset()
        isAwaitingManualApproval = false
        hasReceivedHelloResponse = false
        approvalWaitTask?.cancel()
        connectedHost = host

        var pendingConnection: NWConnection?

        do {
            // Create a direct control connection to the endpoint.
            let parameters = controlParameters(for: controlTransport)
            let connection = NWConnection(to: host.endpoint, using: parameters)
            pendingConnection = connection

            // Wait for connection to be ready.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let continuationBox = ContinuationBox<Void>(continuation)

                connection.stateUpdateHandler = { [continuationBox] state in
                    MirageLogger.client("Connection state: \(state)")
                    switch state {
                    case .ready:
                        continuationBox.resume()
                    case let .failed(error):
                        continuationBox.resume(throwing: error)
                    case .cancelled:
                        continuationBox.resume(throwing: MirageError.protocolError("Connection cancelled"))
                    case let .waiting(error):
                        MirageLogger.client("Connection waiting: \(error)")
                    default:
                        break
                    }
                }

                connection.start(queue: .global(qos: .userInitiated))
            }

            MirageLogger.client("Connected to \(host.name)")
            MirageInstrumentation.record(.clientConnectionEstablished)

            // Store connection for receiving messages.
            self.connection = connection
            loomSession = loomNode.makeSession(connection: connection)
            inputEventSender.updateConnection(connection)

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case let .failed(error):
                    Task { @MainActor in
                        let shouldNotifyDelegate = self.hasReceivedHelloResponse
                        await self.handleDisconnect(
                            reason: error.localizedDescription,
                            state: .error(error.localizedDescription),
                            notifyDelegate: shouldNotifyDelegate
                        )
                    }
                case .cancelled:
                    Task { @MainActor in
                        let shouldNotifyDelegate = self.hasReceivedHelloResponse
                        await self.handleDisconnect(
                            reason: "Connection cancelled",
                            state: .disconnected,
                            notifyDelegate: shouldNotifyDelegate
                        )
                    }
                default:
                    break
                }
            }
            connection.pathUpdateHandler = { [weak self] path in
                let snapshot = MirageNetworkPathClassifier.classify(path)
                MirageLogger.client("Control path updated: \(snapshot.signature)")
                Task { @MainActor [weak self] in
                    self?.handleControlPathUpdate(snapshot)
                }
            }

            try await awaitHelloHandshake(
                on: connection,
                provisionalHost: host
            )
            if let acceptedHost = connectedHost {
                MirageLogger.client("Hello handshake accepted for \(acceptedHost.name)")
            }
        } catch {
            pendingConnection?.cancel()
            MirageLogger.error(.client, error: error, message: "Connection failed: ")
            MirageInstrumentation.record(.clientConnectionFailed)
            if requiresDisconnectCleanupAfterFailedConnect() {
                await handleDisconnect(
                    reason: error.localizedDescription,
                    state: .disconnected,
                    notifyDelegate: false
                )
            }
            throw error
        }
    }

    /// Disconnect from the current host.
    public func disconnect() async {
        // Send disconnect message to host before closing connection.
        if let connection, case .connected = connectionState {
            let disconnectMsg = DisconnectMessage(reason: .userRequested, message: nil)
            if let message = try? ControlMessage(type: .disconnect, content: disconnectMsg) {
                let data = message.serialize()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connection.send(content: data, completion: .contentProcessed { _ in
                        continuation.resume()
                    })
                }
            }
        }

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false
        )
    }

    func handleDisconnect(reason: String, state: ConnectionState, notifyDelegate: Bool) async {
        if case .disconnected = connectionState { return }

        if case .error = connectionState {
            if case .error = state { return }
            if case .disconnected = state { return }
        }

        MirageInstrumentation.record(.clientConnectionDisconnected)

        if !hasReceivedHelloResponse, let helloHandshakeContinuation {
            self.helloHandshakeContinuation = nil
            helloHandshakeContinuation.resume(throwing: MirageError.protocolError(reason))
        }

        let sessions = activeStreams
        let storedSessions = sessionStore.activeSessions

        connection?.cancel()
        connection = nil
        loomSession = nil
        inputEventSender.updateConnection(nil)
        expectedHostIdentityKeyID = nil
        connectedHostIdentityKeyID = nil
        pendingHelloNonce = nil
        helloHandshakeContinuation = nil
        setMediaSecurityContext(nil)
        receiveBuffer = Data()
        stopRegistrationRefreshLoop()
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        activeAppListRequestID = nil
        appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
        pendingForceIconResetForNextAppListRequest = false
        streamingAppBundleID = nil

        for session in sessions {
            await stopViewing(session)
        }

        if let loginDisplayStreamID { MirageFrameCache.shared.clear(for: loginDisplayStreamID) }
        metricsStore.clearAll()
        cursorStore.clearAll()
        cursorPositionStore.clearAll()
        sessionStore.clearLoginDisplayState()

        // Clean up video resources.
        stopVideoConnection()
        stopAudioConnection()

        let controllers = controllersByStream.values
        for controller in controllers {
            await controller.stop()
        }
        controllersByStream.removeAll()
        registeredStreamIDs.removeAll()
        desktopStreamRequestStartTime = 0
        streamStartupBaseTimes.removeAll()
        streamStartupFirstRegistrationSent.removeAll()
        streamStartupFirstPacketReceived.removeAll()
        controlPathSnapshot = nil
        videoPathSnapshot = nil
        audioPathSnapshot = nil
        mediaTransportHost = nil
        mediaTransportIncludePeerToPeer = nil
        activeJitterHoldMs = 0
        adaptiveFallbackBitrateByStream.removeAll()
        adaptiveFallbackBaselineBitrateByStream.removeAll()
        adaptiveFallbackBitDepthByStream.removeAll()
        adaptiveFallbackBaselineBitDepthByStream.removeAll()
        adaptiveFallbackCollapseTimestampsByStream.removeAll()
        adaptiveFallbackPressureCountByStream.removeAll()
        adaptiveFallbackLastPressureTriggerTimeByStream.removeAll()
        adaptiveFallbackStableSinceByStream.removeAll()
        adaptiveFallbackLastRestoreTimeByStream.removeAll()
        adaptiveFallbackLastCollapseTimeByStream.removeAll()
        adaptiveFallbackLastAppliedTime.removeAll()
        pendingAdaptiveFallbackBitrateByWindowID.removeAll()
        pendingAdaptiveFallbackBitDepthByWindowID.removeAll()
        pendingDesktopAdaptiveFallbackBitrate = nil
        pendingDesktopAdaptiveFallbackBitDepth = nil
        pendingAppAdaptiveFallbackBitrate = nil
        pendingAppAdaptiveFallbackBitDepth = nil
        desktopDimensionTokenByStream.removeAll()
        fastPathState.clearAllStartupPacketPending()
        for task in startupRegistrationRetryTasks.values { task.cancel() }
        startupRegistrationRetryTasks.removeAll()
        activeStreams.removeAll()
        for session in storedSessions {
            sessionStore.removeSession(session.id)
        }
        await updateReassemblerSnapshot()

        // Clear active stream IDs (thread-safe).
        clearAllActiveStreamIDs()

        // Reset session state.
        hostSessionState = nil
        currentSessionToken = nil
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        isAwaitingManualApproval = false
        approvalWaitTask?.cancel()
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        if let pingContinuation {
            self.pingContinuation = nil
            pingContinuation.resume(throwing: MirageError.protocolError(reason))
        }
        completeQualityTestWaiter(result: nil)
        hasReceivedHelloResponse = false
        negotiatedFeatures = []
        mediaPayloadEncryptionEnabled = true
        desktopStreamID = nil
        desktopStreamResolution = nil
        desktopStreamMode = nil
        connectionState = state

        if notifyDelegate { delegate?.clientService(self, didDisconnectFromHost: reason) }
    }

    private func startManualApprovalWaitTimer() {
        approvalWaitTask?.cancel()
        approvalWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self else { return }
            guard Self.shouldActivateManualApprovalWaitIndicator(
                hasReceivedHelloResponse: hasReceivedHelloResponse,
                connectionState: connectionState
            ) else {
                return
            }

            if case .handshaking = connectionState {
                isAwaitingManualApproval = true
            }
        }
    }

    static func shouldActivateManualApprovalWaitIndicator(
        hasReceivedHelloResponse: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        guard !hasReceivedHelloResponse else { return false }
        if case .handshaking = connectionState {
            return true
        }
        return false
    }

    private func requiresDisconnectCleanupAfterFailedConnect() -> Bool {
        switch connectionState {
        case .disconnected,
             .error:
            return connection != nil ||
                loomSession != nil ||
                pendingHelloNonce != nil ||
                helloHandshakeContinuation != nil
        case .connecting,
             .handshaking,
             .connected,
             .reconnecting:
            return true
        }
    }

}
