//
//  MirageClientService+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client connection lifecycle and Loom session bootstrap.
//

import Foundation
import Loom
import Network
import MirageKit

#if canImport(UIKit)
import UIKit.UIDevice
#endif

#if canImport(AppKit)
import AppKit
#endif

enum MirageControlEndpointAttemptSource: String, Sendable {
    case direct = "direct"
    case bonjourService = "bonjour_service"
    case resolvedBonjourService = "resolved_bonjour_service"
}

struct MirageControlEndpointAttempt: Sendable {
    let endpoint: NWEndpoint
    let source: MirageControlEndpointAttemptSource
}

@MainActor
extension MirageClientService {
    func controlParameters(for transport: ControlTransport) -> NWParameters {
        switch transport {
        case .tcp:
            let parameters = NWParameters.tcp
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
            parameters.includePeerToPeer = networkConfig.enablePeerToPeer
            parameters.allowLocalEndpointReuse = true
            return parameters
        }
    }

    private var currentDeviceType: DeviceType {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #elseif os(visionOS)
        return .vision
        #else
        return .unknown
        #endif
    }

    func makeSessionHelloRequest() throws -> LoomSessionHelloRequest {
        let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
        let identity = try resolvedIdentityManager.currentIdentity()
        let advertisement = MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: currentDeviceType,
            identityKeyID: identity.keyID
        )
        return LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: currentDeviceType,
            advertisement: advertisement,
            iCloudUserID: iCloudUserID
        )
    }

    func makeBootstrapRequest(
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) -> MirageSessionBootstrapRequest {
        MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.protocolVersion),
            requestedFeatures: mirageSupportedFeatures,
            requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
        )
    }

    public func connect(
        to host: LoomPeer,
        controlTransport: ControlTransport = .tcp
    ) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        let attemptID = beginConnectAttempt()
        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name) using \(controlTransport)...")
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        connectedHostAllowsRemoteAccess = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        isAwaitingManualApproval = false
        hasCompletedBootstrap = false
        approvalWaitTask?.cancel()
        connectedHost = host

        var pendingChannel: MirageControlChannel?
        let helloRequest = try makeSessionHelloRequest()

        do {
            let transportKind: LoomTransportKind = controlTransport == .quic ? .quic : .tcp
            let session = try await connectSession(
                to: host,
                transportKind: transportKind,
                hello: helloRequest,
                attemptID: attemptID
            )
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            let controlChannel = try await MirageControlChannel.open(on: session)
            pendingChannel = controlChannel
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)

            loomSession = session
            self.controlChannel = controlChannel
            inputEventSender.updateSendHandler { [weak controlChannel] data, _ in
                guard let controlChannel else {
                    throw MirageError.protocolError("Control channel unavailable")
                }
                try await controlChannel.sendSerialized(data)
            }
            installControlSessionObservers(session)
            try await performBootstrap(over: controlChannel, provisionalHost: host)
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            startReceiving()
            finishConnectAttempt(attemptID)
            startHeartbeat()

            if let acceptedHost = connectedHost {
                MirageLogger.client("Mirage bootstrap accepted for \(acceptedHost.name)")
            }
        } catch {
            if let pendingChannel {
                await pendingChannel.cancel()
            }
            cancelPendingConnectTask(attemptID: attemptID)
            finishConnectAttempt(attemptID)
            if hasCompletedBootstrap {
                MirageLogger.error(.client, error: error, message: "Connection failed: ")
            } else {
                MirageLogger.client("Connection failed before bootstrap completed: \(error.localizedDescription)")
            }
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

    public func disconnect() async {
        cancelPendingConnectTask()
        invalidateCurrentConnectAttempt()

        if let controlChannel, case .connected = connectionState {
            let disconnectMsg = DisconnectMessage(reason: .userRequested, message: nil)
            try? await controlChannel.send(.disconnect, content: disconnectMsg)
        }

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false
        )
    }

    func handleDisconnect(reason: String, state: ConnectionState, notifyDelegate: Bool) async {
        if case .disconnected = connectionState {
            return
        }

        if case .error = connectionState {
            if case .error = state {
                return
            }
            if case .disconnected = state {
                return
            }
        }

        MirageInstrumentation.record(.clientConnectionDisconnected)

        let sessions = activeStreams
        let storedSessions = sessionStore.activeSessions
        let disconnectedControlChannel = controlChannel
        let disconnectedLoomSession = loomSession

        self.controlChannel = nil
        loomSession = nil

        if let disconnectedControlChannel {
            await disconnectedControlChannel.cancel()
        } else {
            await disconnectedLoomSession?.cancel()
        }
        cancelPendingConnectTask()
        invalidateCurrentConnectAttempt()
        controlSessionStateObserverTask?.cancel()
        controlSessionStateObserverTask = nil
        controlSessionPathObserverTask?.cancel()
        controlSessionPathObserverTask = nil
        sharedClipboardEnabled = false
        sharedClipboardBridge?.setActive(false)
        inputEventSender.updateSendHandler(nil)
        expectedHostIdentityKeyID = nil
        connectedHostIdentityKeyID = nil
        connectedHostAllowsRemoteAccess = nil
        setMediaSecurityContext(nil)
        receiveBuffer = Data()
        stopRegistrationRefreshLoop()
        stopHeartbeat()
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        activeAppListRequestID = nil
        appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
        pendingForceIconResetForNextAppListRequest = false
        streamingAppBundleID = nil
        hostDataPort = 0

        for session in sessions {
            await stopViewing(session)
        }

        if let loginDisplayStreamID {
            MirageFrameCache.shared.clear(for: loginDisplayStreamID)
        }
        metricsStore.clearAll()
        cursorStore.clearAll()
        cursorPositionStore.clearAll()
        sessionStore.clearLoginDisplayState()

        mediaPathProber?.stopMonitoring()
        mediaPathProber = nil
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
        adaptiveFallbackColorDepthByStream.removeAll()
        adaptiveFallbackBaselineColorDepthByStream.removeAll()
        adaptiveFallbackCollapseTimestampsByStream.removeAll()
        adaptiveFallbackPressureCountByStream.removeAll()
        adaptiveFallbackLastPressureTriggerTimeByStream.removeAll()
        adaptiveFallbackStableSinceByStream.removeAll()
        adaptiveFallbackLastRestoreTimeByStream.removeAll()
        adaptiveFallbackLastCollapseTimeByStream.removeAll()
        adaptiveFallbackLastAppliedTime.removeAll()
        pendingAdaptiveFallbackBitrateByWindowID.removeAll()
        pendingAdaptiveFallbackColorDepthByWindowID.removeAll()
        pendingDesktopAdaptiveFallbackBitrate = nil
        pendingDesktopAdaptiveFallbackColorDepth = nil
        pendingAppAdaptiveFallbackBitrate = nil
        pendingAppAdaptiveFallbackColorDepth = nil
        desktopDimensionTokenByStream.removeAll()
        fastPathState.clearAllStartupPacketPending()
        for task in startupRegistrationRetryTasks.values {
            task.cancel()
        }
        startupRegistrationRetryTasks.removeAll()
        activeStreams.removeAll()
        for session in storedSessions {
            sessionStore.removeSession(session.id)
        }
        await updateReassemblerSnapshot()

        clearAllActiveStreamIDs()

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
        if let hostSupportLogArchiveContinuation {
            self.hostSupportLogArchiveContinuation = nil
            hostSupportLogArchiveRequestID = nil
            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = nil
            hostSupportLogArchiveTimeoutTask?.cancel()
            hostSupportLogArchiveTimeoutTask = nil
            hostSupportLogArchiveContinuation.resume(throwing: MirageError.protocolError(reason))
        }
        hasCompletedBootstrap = false
        negotiatedFeatures = []
        mediaPayloadEncryptionEnabled = true
        desktopStreamID = nil
        desktopStreamResolution = nil
        desktopStreamMode = nil
        connectionState = state
        refreshSharedClipboardBridgeState()

        if notifyDelegate {
            delegate?.clientService(self, didDisconnectFromHost: reason)
        }
    }

    private func connectSession(
        to host: LoomPeer,
        transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        let initialAttempt = controlEndpointAttempts(for: host, transportKind: transportKind).first
            ?? MirageControlEndpointAttempt(endpoint: host.endpoint, source: .direct)

        let interfaceType = preferredNetworkType.requiredInterfaceType

        do {
            return try await establishControlSession(
                to: initialAttempt.endpoint,
                source: initialAttempt.source,
                hostName: host.name,
                transportKind: transportKind,
                hello: hello,
                attemptID: attemptID,
                requiredInterfaceType: interfaceType
            )
        } catch let firstError {
            guard shouldRetryWithResolvedBonjourEndpoint(for: host, after: firstError) else {
                throw firstError
            }

            // Retry up to 2 more times with NECP flushes between attempts.
            // The macOS NECP TLV encoding bug corrupts path parameters system-wide.
            // Toggling P2P forces NECP to rebuild its cache. We retry the same
            // service endpoint instead of resolving via Bonjour (which also hangs
            // when NECP is corrupted since the resolver uses NWConnection internally).
            for retryIndex in 1...2 {
                try throwIfConnectAttemptIsStale(attemptID)
                await flushNECPPolicyState()

                MirageLogger.client(
                    "NECP retry \(retryIndex)/2 for \(host.name) via \(initialAttempt.source.rawValue)"
                )

                do {
                    return try await establishControlSession(
                        to: initialAttempt.endpoint,
                        source: initialAttempt.source,
                        hostName: host.name,
                        transportKind: transportKind,
                        hello: hello,
                        attemptID: attemptID,
                        requiredInterfaceType: interfaceType
                    )
                } catch {
                    if error is CancellationError {
                        throw error
                    }
                    MirageLogger.client(
                        "NECP retry \(retryIndex)/2 failed for \(host.name): \(error.localizedDescription)"
                    )
                    continue
                }
            }

            throw firstError
        }
    }

    func controlEndpointAttempts(
        for host: LoomPeer,
        transportKind _: LoomTransportKind,
        resolvedBonjourEndpoint: NWEndpoint? = nil
    ) -> [MirageControlEndpointAttempt] {
        guard case .service = host.endpoint else {
            return [MirageControlEndpointAttempt(endpoint: host.endpoint, source: .direct)]
        }

        var attempts = [MirageControlEndpointAttempt(endpoint: host.endpoint, source: .bonjourService)]
        if let resolvedBonjourEndpoint,
           resolvedBonjourEndpoint.debugDescription != host.endpoint.debugDescription {
            attempts.append(
                MirageControlEndpointAttempt(
                    endpoint: resolvedBonjourEndpoint,
                    source: .resolvedBonjourService
                )
            )
        }
        return attempts
    }

    private func establishControlSession(
        to endpoint: NWEndpoint,
        source: MirageControlEndpointAttemptSource,
        hostName: String,
        transportKind: LoomTransportKind,
        hello: LoomSessionHelloRequest,
        attemptID: UUID,
        enablePeerToPeer: Bool? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil
    ) async throws -> LoomAuthenticatedSession {
        try throwIfConnectAttemptIsStale(attemptID)
        MirageLogger.client(
            "Starting \(transportKind) control session to \(hostName) via \(source.rawValue) endpoint=\(endpoint)"
        )
        let node = loomNode
        let connectTask = Task<LoomAuthenticatedSession, Error> { [weak self] in
            let session = try await node.connect(
                to: endpoint,
                using: transportKind,
                hello: hello,
                enablePeerToPeer: enablePeerToPeer,
                requiredInterfaceType: requiredInterfaceType
            )
            let shouldCancelSession = await MainActor.run {
                guard let self else { return true }
                return !self.isCurrentConnectAttempt(attemptID)
            }
            if shouldCancelSession {
                await session.cancel()
                throw CancellationError()
            }
            return session
        }
        pendingConnectTask = connectTask
        pendingConnectTaskAttemptID = attemptID

        do {
            let session = try await awaitConnectSession(
                connectTask,
                endpoint: endpoint,
                transportKind: transportKind,
                attemptID: attemptID
            )
            clearPendingConnectTaskIfNeeded(for: attemptID)
            return session
        } catch {
            clearPendingConnectTaskIfNeeded(for: attemptID)
            throw error
        }
    }

    private func shouldRetryWithResolvedBonjourEndpoint(
        for host: LoomPeer,
        after error: Error
    ) -> Bool {
        guard case .service = host.endpoint else {
            return false
        }
        if error is CancellationError {
            return false
        }
        if let error = error as? LoomError {
            switch error {
            case .authenticationFailed, .protocolError:
                return false
            default:
                break
            }
        }
        return true
    }

    /// Toggles `includePeerToPeer` on the Loom node configuration to force NECP
    /// to discard its cached (possibly corrupted) path parameters and rebuild them.
    private func flushNECPPolicyState() async {
        let original = networkConfig.enablePeerToPeer
        networkConfig.enablePeerToPeer = !original
        loomNode.configuration = networkConfig
        try? await Task.sleep(for: .milliseconds(50))
        networkConfig.enablePeerToPeer = original
        loomNode.configuration = networkConfig
        MirageLogger.client("Flushed NECP policy state (toggled P2P \(original) → \(!original) → \(original))")
    }

    private func resolvedBonjourFallbackEndpoint(
        for host: LoomPeer,
        transportKind: LoomTransportKind
    ) async throws -> NWEndpoint {
        let endpoint = try await MirageBonjourServiceEndpointResolver.resolve(
            endpoint: host.endpoint,
            advertisement: host.advertisement,
            transportKind: transportKind,
            enablePeerToPeer: networkConfig.enablePeerToPeer
        )
        MirageLogger.client(
            "Resolved Bonjour fallback endpoint for \(host.name) transport=\(transportKind) endpoint=\(endpoint)"
        )
        return endpoint
    }

    /// Races `connectTask` against `controlSessionConnectTimeout` using a
    /// continuation so the timeout can fire immediately without waiting for
    /// `NWConnection` to acknowledge cancellation (which may never happen when
    /// the macOS NECP policy engine is in a corrupted state).
    private func awaitConnectSession(
        _ connectTask: Task<LoomAuthenticatedSession, Error>,
        endpoint: NWEndpoint,
        transportKind: LoomTransportKind,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        let timeout = controlSessionConnectTimeout
        let timeoutError = MirageError.protocolError(
            "Timed out establishing \(transportKind) control session to \(endpoint)"
        )

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = ConnectSessionContinuationBox(continuation)

                Task {
                    do {
                        let session = try await connectTask.value
                        await box.resume(returning: session)
                    } catch {
                        await box.resume(throwing: error)
                    }
                }

                Task { [timeout, timeoutError] in
                    try? await Task.sleep(for: timeout)
                    connectTask.cancel()
                    await box.resume(throwing: timeoutError)
                }
            }
        } catch {
            if isCurrentConnectAttempt(attemptID) {
                cancelPendingConnectTask(attemptID: attemptID)
            }
            throw error
        }
    }

    private func beginConnectAttempt() -> UUID {
        let attemptID = UUID()
        currentConnectAttemptID = attemptID
        return attemptID
    }

    private func finishConnectAttempt(_ attemptID: UUID) {
        guard currentConnectAttemptID == attemptID else { return }
        currentConnectAttemptID = nil
    }

    private func invalidateCurrentConnectAttempt() {
        currentConnectAttemptID = nil
    }

    private func isCurrentConnectAttempt(_ attemptID: UUID) -> Bool {
        currentConnectAttemptID == attemptID
    }

    private func throwIfConnectAttemptIsStale(_ attemptID: UUID) throws {
        guard isCurrentConnectAttempt(attemptID) else {
            throw CancellationError()
        }
    }

    private func cancelPendingConnectTask(attemptID: UUID? = nil) {
        guard attemptID == nil || pendingConnectTaskAttemptID == attemptID else {
            return
        }
        pendingConnectTask?.cancel()
        pendingConnectTask = nil
        pendingConnectTaskAttemptID = nil
    }

    private func clearPendingConnectTaskIfNeeded(for attemptID: UUID) {
        guard pendingConnectTaskAttemptID == attemptID else { return }
        pendingConnectTask = nil
        pendingConnectTaskAttemptID = nil
    }

    private func performBootstrap(
        over controlChannel: MirageControlChannel,
        provisionalHost: LoomPeer,
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) async throws {
        connectionState = .handshaking(host: provisionalHost.name)
        MirageInstrumentation.record(.clientHelloSent)
        MirageLogger.client("Sending Mirage bootstrap request to \(provisionalHost.name)")
        try await controlChannel.send(
            .sessionBootstrapRequest,
            content: makeBootstrapRequest(
                requestHostUpdateOnProtocolMismatch: requestHostUpdateOnProtocolMismatch
            )
        )
        startManualApprovalWaitTimer()

        MirageLogger.client("Waiting for Mirage bootstrap response from \(provisionalHost.name)")
        let responseMessage = try await receiveSingleControlMessage(
            from: controlChannel.incomingBytes,
            timeout: bootstrapResponseTimeout,
            timeoutMessage: "Timed out waiting for host bootstrap response from \(provisionalHost.name)"
        )
        guard responseMessage.type == .sessionBootstrapResponse else {
            throw MirageError.protocolError("Expected Mirage session bootstrap response")
        }
        MirageLogger.client("Received Mirage bootstrap response from \(provisionalHost.name)")
        let response = try responseMessage.decode(MirageSessionBootstrapResponse.self)
        try await handleBootstrapResponse(
            response,
            provisionalHost: provisionalHost,
            session: controlChannel.session
        )
    }

    func receiveSingleControlMessage(
        from stream: AsyncStream<Data>,
        timeout: Duration? = nil,
        timeoutMessage: String? = nil
    ) async throws -> ControlMessage {
        if let timeout,
           let timeoutMessage {
            return try await withThrowingTaskGroup(of: ControlMessage.self) { group in
                group.addTask {
                    try await self.receiveSingleControlMessageUnbounded(from: stream)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MirageError.protocolError(timeoutMessage)
                }

                let message = try await group.next() ?? {
                    throw MirageError.protocolError("Control message receive ended unexpectedly")
                }()
                group.cancelAll()
                return message
            }
        }

        return try await receiveSingleControlMessageUnbounded(from: stream)
    }

    private func receiveSingleControlMessageUnbounded(
        from stream: AsyncStream<Data>
    ) async throws -> ControlMessage {
        var buffer = Data()

        for await chunk in stream {
            guard !chunk.isEmpty else { continue }
            buffer.append(chunk)

            switch ControlMessage.deserialize(from: buffer) {
            case let .success(message, consumed):
                if consumed < buffer.count {
                    receiveBuffer = Data(buffer.dropFirst(consumed))
                }
                return message
            case .needMoreData:
                continue
            case let .invalidFrame(reason):
                throw MirageError.protocolError("Invalid control frame: \(reason)")
            }
        }

        throw MirageError.protocolError("Control stream closed before receiving bootstrap response")
    }

    private func installControlSessionObservers(_ session: LoomAuthenticatedSession) {
        controlSessionStateObserverTask?.cancel()
        controlSessionStateObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let observer = await session.makeStateObserver()
            for await state in observer {
                guard self.loomSession?.id == session.id else { break }
                switch state {
                case let .failed(reason):
                    await self.handleDisconnect(
                        reason: reason,
                        state: .error(reason),
                        notifyDelegate: self.hasCompletedBootstrap
                    )
                case .cancelled:
                    await self.handleDisconnect(
                        reason: "Connection cancelled",
                        state: .disconnected,
                        notifyDelegate: self.hasCompletedBootstrap
                    )
                default:
                    continue
                }
                break
            }
        }

        controlSessionPathObserverTask?.cancel()
        controlSessionPathObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let observer = await session.makePathObserver()
            for await pathSnapshot in observer {
                guard self.loomSession?.id == session.id else { break }
                let snapshot = MirageNetworkPathClassifier.classify(pathSnapshot)
                MirageLogger.client("Control path updated: \(snapshot.signature)")
                self.handleControlPathUpdate(snapshot)
            }
        }
    }

    private func startManualApprovalWaitTimer() {
        approvalWaitTask?.cancel()
        approvalWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self else { return }
            guard Self.shouldActivateManualApprovalWaitIndicator(
                hasCompletedBootstrap: hasCompletedBootstrap,
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
        hasCompletedBootstrap: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        guard !hasCompletedBootstrap else { return false }
        if case .handshaking = connectionState {
            return true
        }
        return false
    }

    private func requiresDisconnectCleanupAfterFailedConnect() -> Bool {
        switch connectionState {
        case .disconnected, .error:
            return controlChannel != nil || loomSession != nil
        case .connecting, .handshaking, .connected, .reconnecting:
            return true
        }
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once when racing
/// a connect task against a timeout. The first caller to `resume` wins;
/// subsequent calls are silently ignored.
private actor ConnectSessionContinuationBox {
    private var continuation: CheckedContinuation<LoomAuthenticatedSession, Error>?

    init(_ continuation: CheckedContinuation<LoomAuthenticatedSession, Error>) {
        self.continuation = continuation
    }

    func resume(returning session: LoomAuthenticatedSession) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: session)
    }

    func resume(throwing error: Error) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(throwing: error)
    }
}
