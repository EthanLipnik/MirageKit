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

@MainActor
extension MirageClientService {
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

    public func makeSessionHelloRequest() throws -> LoomSessionHelloRequest {
        let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
        let identity = try resolvedIdentityManager.currentIdentity()
        let advertisement = MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: currentDeviceType,
            identityKeyID: identity.keyID,
            additionalMetadata: additionalAdvertisementMetadata
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
        withEstablishedSession session: LoomAuthenticatedSession,
        host: LoomPeer
    ) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        let attemptID = beginConnectAttempt()
        beginConnectionStartupCriticalSection()
        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name) using established session...")
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        connectedHostAllowsRemoteAccess = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        isAwaitingManualApproval = false
        hasCompletedBootstrap = false
        connectedHost = host

        var pendingChannel: MirageControlChannel?

        do {
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
            startMediaStreamListener()
            try await performBootstrap(over: controlChannel, provisionalHost: host)
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            startReceiving()
            finishConnectAttempt(attemptID)
            armConnectionStartupIdleRelease()

            // The host immediately streams a large hardware icon (~1 MB) plus
            // app-icon updates after bootstrap.  Give the initial data exchange
            // time to complete before the heartbeat starts probing.
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            startHeartbeat()

            if let acceptedHost = connectedHost {
                MirageLogger.client("Mirage bootstrap accepted for \(acceptedHost.name)")
            }
        } catch {
            clearStartupCriticalSection()
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

    public func connect(to host: LoomPeer) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        let attemptID = beginConnectAttempt()
        beginConnectionStartupCriticalSection()
        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name)...")
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        connectedHostAllowsRemoteAccess = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        isAwaitingManualApproval = false
        hasCompletedBootstrap = false
        connectedHost = host

        var pendingChannel: MirageControlChannel?
        let helloRequest = try makeSessionHelloRequest()

        do {
            let session = try await connectSession(
                to: host,
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
            startMediaStreamListener()
            try await performBootstrap(over: controlChannel, provisionalHost: host)
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            startReceiving()
            finishConnectAttempt(attemptID)
            armConnectionStartupIdleRelease()

            // The host immediately streams a large hardware icon (~1 MB) plus
            // app-icon updates after bootstrap.  Give the initial data exchange
            // time to complete before the heartbeat starts probing.
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            startHeartbeat()

            if let acceptedHost = connectedHost {
                MirageLogger.client("Mirage bootstrap accepted for \(acceptedHost.name)")
            }
        } catch {
            clearStartupCriticalSection()
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

    /// Pause all streams without disconnecting.  The host stops encoding
    /// but keeps virtual displays and stream infrastructure alive so that
    /// `resumeStreaming()` can restart frames immediately with a keyframe.
    public func pauseStreaming() {
        sendControlMessageBestEffort(ControlMessage(type: .streamPauseAll))
        MirageLogger.client("Sent streamPauseAll to host")
    }

    /// Resume all streams after a pause.  The host forces a keyframe so
    /// the decoder can immediately begin presenting frames again.
    public func resumeStreaming() {
        sendControlMessageBestEffort(ControlMessage(type: .streamResumeAll))
        MirageLogger.client("Sent streamResumeAll to host")
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
        clearStartupCriticalSection()
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
        for session in sessions {
            await stopViewing(session)
        }

        metricsStore.clearAll()
        cursorStore.clearAll()
        cursorPositionStore.clearAll()

        stopMediaStreamListener()
        stopAudioConnection()

        let controllers = controllersByStream.values
        for controller in controllers {
            await controller.stop()
        }
        controllersByStream.removeAll()
        startupAttemptIDByStream.removeAll()
        registeredStreamIDs.removeAll()
        desktopStreamRequestStartTime = 0
        streamStartupBaseTimes.removeAll()
        streamStartupFirstRegistrationSent.removeAll()
        streamStartupFirstPacketReceived.removeAll()
        controlPathSnapshot = nil
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
        isAwaitingManualApproval = false
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
            hostSupportLogArchiveContinuation.resume(throwing: CancellationError())
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
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        try throwIfConnectAttemptIsStale(attemptID)

        let attempts = controlSessionAttempts(for: host)
        var lastFailureReason: String?

        for attempt in attempts {
            try throwIfConnectAttemptIsStale(attemptID)
            do {
                return try await establishControlSession(
                    attempt: attempt,
                    hello: hello,
                    attemptID: attemptID
                )
            } catch {
                let classification = Self.classifyControlSessionFailure(error)
                if error is CancellationError || classification == .cancelled {
                    throw error
                }

                let failureReason = Self.controlSessionFailureReason(
                    for: attempt,
                    classification: classification,
                    underlyingError: error
                )
                lastFailureReason = failureReason

                if attempt.transportKind == .udp,
                   classification.shouldRetryOverTCP,
                   attempts.contains(where: { $0.transportKind == .tcp }) {
                    MirageLogger.client("\(failureReason); retrying over advertised TCP")
                    continue
                }

                throw MirageError.protocolError(failureReason)
            }
        }

        throw MirageError.protocolError(
            lastFailureReason ?? "Failed to establish control session to \(host.name)"
        )
    }

    private func establishControlSession(
        attempt: ControlSessionAttempt,
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        try throwIfConnectAttemptIsStale(attemptID)
        MirageLogger.client(
            "Starting \(attempt.transportKind) control session to \(attempt.hostName) " +
                "endpoint=\(attempt.endpoint) interface=\(attempt.interfaceDescription)"
        )
        let node = loomNode
        let connectTask = Task<LoomAuthenticatedSession, Error> { [weak self] in
            let session = try await node.connect(
                to: attempt.endpoint,
                using: attempt.transportKind,
                hello: hello,
                requiredInterfaceType: attempt.requiredInterfaceType,
                onTrustPending: { @MainActor [weak self] in
                    self?.isAwaitingManualApproval = true
                }
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
                attemptID: attemptID
            )
            clearPendingConnectTaskIfNeeded(for: attemptID)
            return session
        } catch {
            clearPendingConnectTaskIfNeeded(for: attemptID)
            throw error
        }
    }

    /// Races `connectTask` against `controlSessionConnectTimeout` using a
    /// continuation so the timeout can fire immediately without waiting for
    /// `NWConnection` to acknowledge cancellation (which may never happen when
    /// the macOS NECP policy engine is in a corrupted state).
    private func awaitConnectSession(
        _ connectTask: Task<LoomAuthenticatedSession, Error>,
        attemptID: UUID
    ) async throws -> LoomAuthenticatedSession {
        let timeout = controlSessionConnectTimeout
        let timeoutError = MirageError.timeout

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

    func controlSessionAttempts(for host: LoomPeer) -> [ControlSessionAttempt] {
        let requiredInterfaceType = preferredNetworkType.requiredInterfaceType
        var attempts: [ControlSessionAttempt] = []

        if let udpTransport = host.advertisement.directTransports.first(where: { $0.transportKind == .udp }),
           let port = NWEndpoint.Port(rawValue: udpTransport.port),
           let udpHost = controlSessionUDPHost(for: host) {
            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: .hostPort(host: udpHost, port: port),
                    transportKind: .udp,
                    requiredInterfaceType: requiredInterfaceType
                )
            )
        }

        let tcpAttempt = ControlSessionAttempt(
            hostName: host.name,
            endpoint: host.endpoint,
            transportKind: .tcp,
            requiredInterfaceType: requiredInterfaceType
        )

        if attempts.isEmpty {
            attempts.append(tcpAttempt)
        } else if attempts[0].endpoint.debugDescription != tcpAttempt.endpoint.debugDescription {
            attempts.append(tcpAttempt)
        }

        return attempts
    }

    private func controlSessionUDPHost(for host: LoomPeer) -> NWEndpoint.Host? {
        let advertisedHostName = host.advertisement.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let advertisedHostName, !advertisedHostName.isEmpty {
            let expandedHosts = Self.expandedBonjourHosts(for: NWEndpoint.Host(advertisedHostName))
            if let preferredHost = expandedHosts.first {
                return preferredHost
            }
        }

        let peerName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerName.isEmpty else { return nil }
        return Self.expandedBonjourHosts(for: NWEndpoint.Host(peerName)).first
    }

    internal struct ControlSessionAttempt {
        let hostName: String
        let endpoint: NWEndpoint
        let transportKind: LoomTransportKind
        let requiredInterfaceType: NWInterface.InterfaceType?

        var interfaceDescription: String {
            requiredInterfaceType.map(String.init(describing:)) ?? "any"
        }
    }

    internal enum ControlSessionFailureClassification: String {
        case timeout
        case transportLoss
        case connectionRefused
        case addressUnavailable
        case cancelled
        case other

        var shouldRetryOverTCP: Bool {
            switch self {
            case .timeout, .transportLoss, .connectionRefused, .addressUnavailable:
                true
            case .cancelled, .other:
                false
            }
        }
    }

    internal static func classifyControlSessionFailure(_ error: Error) -> ControlSessionFailureClassification {
        if error is CancellationError {
            return .cancelled
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case .timeout:
                return .timeout
            case let .connectionFailed(underlyingError):
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case .timeout:
                return .timeout
            case let .connectionFailed(underlyingError):
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let nwError = error as? NWError {
            return classifyNetworkFailure(nwError)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classifyPOSIXError(code)
        }

        return .other
    }

    internal static func controlSessionFailureReason(
        for attempt: ControlSessionAttempt,
        classification: ControlSessionFailureClassification,
        underlyingError: Error
    ) -> String {
        "Pre-bootstrap \(attempt.transportKind.rawValue) control session failed for " +
            "\(attempt.hostName) endpoint=\(attempt.endpoint) interface=\(attempt.interfaceDescription) " +
            "classification=\(classification.rawValue) error=\(underlyingError.localizedDescription)"
    }

    private static func classifyNetworkFailure(_ error: NWError) -> ControlSessionFailureClassification {
        switch error {
        case let .posix(code):
            return classifyPOSIXError(code)
        case .dns,
             .tls:
            return .other
        @unknown default:
            return .other
        }
    }

    private static func classifyPOSIXError(_ code: POSIXErrorCode) -> ControlSessionFailureClassification {
        switch code {
        case .ETIMEDOUT:
            .timeout
        case .ECONNREFUSED:
            .connectionRefused
        case .EADDRNOTAVAIL:
            .addressUnavailable
        case .ENETDOWN,
             .ENETUNREACH,
             .EHOSTDOWN,
             .EHOSTUNREACH,
             .ENETRESET,
             .ECONNABORTED,
             .ECONNRESET,
             .ENOTCONN,
             .EPIPE:
            .transportLoss
        case .ECANCELED:
            .cancelled
        default:
            .other
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

    @discardableResult
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
