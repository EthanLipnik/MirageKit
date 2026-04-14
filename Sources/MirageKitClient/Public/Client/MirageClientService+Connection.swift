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
    private struct BootstrappedControlSession {
        let session: LoomAuthenticatedSession
        let controlChannel: MirageControlChannel
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
        resetControlPathHistory()

        var pendingChannel: MirageControlChannel?

        do {
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            let controlChannel = try await MirageControlChannel.open(on: session)
            pendingChannel = controlChannel
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            try await performBootstrap(over: controlChannel, provisionalHost: host)
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)

            loomSession = session
            rememberDirectEndpointHost(await session.remoteEndpoint, for: host.deviceID)
            transferEngine = LoomTransferEngine(session: session)
            startTransferObserver()
            self.controlChannel = controlChannel
            inputEventSender.updateSendHandler { [weak controlChannel] data, _ in
                guard let controlChannel else {
                    throw MirageError.protocolError("Control channel unavailable")
                }
                try await controlChannel.sendSerialized(data)
            }
            installControlSessionObservers(session)
            startMediaStreamListener()
            startReceiving()
            fastPathState.resetInboundActivity(now: CFAbsoluteTimeGetCurrent())
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
        resetControlPathHistory()

        var pendingChannel: MirageControlChannel?
        let helloRequest = try makeSessionHelloRequest()

        do {
            let bootstrappedSession = try await connectBootstrappedControlSession(
                to: host,
                hello: helloRequest,
                attemptID: attemptID
            )
            let session = bootstrappedSession.session
            let controlChannel = bootstrappedSession.controlChannel
            pendingChannel = controlChannel
            loomSession = session
            rememberDirectEndpointHost(await session.remoteEndpoint, for: host.deviceID)
            transferEngine = LoomTransferEngine(session: session)
            startTransferObserver()
            self.controlChannel = controlChannel
            inputEventSender.updateSendHandler { [weak controlChannel] data, _ in
                guard let controlChannel else {
                    throw MirageError.protocolError("Control channel unavailable")
                }
                try await controlChannel.sendSerialized(data)
            }
            installControlSessionObservers(session)
            startMediaStreamListener()
            startReceiving()
            fastPathState.resetInboundActivity(now: CFAbsoluteTimeGetCurrent())
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
        transferEngine = nil
        stopTransferObserver()

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
        await sharedClipboardBridge?.setActive(false)
        inputEventSender.updateSendHandler(nil)
        expectedHostIdentityKeyID = nil
        connectedHostIdentityKeyID = nil
        connectedHostAllowsRemoteAccess = nil
        setMediaSecurityContext(nil)
        receiveBuffer = Data()
        stopRegistrationRefreshLoop()
        stopHeartbeat()
        fastPathState.resetInboundActivity()
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        activeAppListRequestID = nil
        appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
        pendingForceIconResetForNextAppListRequest = false
        deferredControlRefreshRequirements = .none
        droppedAppIconUpdateMessagesWhileSuppressed = 0
        setControlUpdatePolicy(.normal)
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
        cancelDesktopStreamStopTimeout()
        desktopStreamRequestStartTime = 0
        streamStartupBaseTimes.removeAll()
        streamStartupFirstRegistrationSent.removeAll()
        streamStartupFirstPacketReceived.removeAll()
        controlPathSnapshot = nil
        resetControlPathHistory()
        activeJitterHoldMs = 0
        decoderCompatibilityCurrentColorDepthByStream.removeAll()
        decoderCompatibilityBaselineColorDepthByStream.removeAll()
        decoderCompatibilityFallbackLastAppliedTime.removeAll()
        pendingRequestedColorDepthByWindowID.removeAll()
        pendingDesktopRequestedColorDepth = nil
        pendingAppRequestedColorDepth = nil
        desktopDimensionTokenByStream.removeAll()
        appStreamStartAcknowledgementByStreamID.removeAll()
        fastPathState.clearAllStartupPacketPending()
        fastPathState.clearDiagnostics()
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
        failActivePingRequests(with: MirageError.protocolError(reason))
        qualityTestPendingTestID = nil
        qualityTestBenchmarkTimeoutTask?.cancel()
        qualityTestBenchmarkTimeoutTask = nil
        qualityTestStageCompletionTimeoutTask?.cancel()
        qualityTestStageCompletionTimeoutTask = nil
        completeQualityTestBenchmarkWaiter(result: nil)
        completeQualityTestStageCompletionWaiter(result: nil)
        qualityTestStageCompletionBuffer.removeAll()
        clearQualityTestAccumulator()
        for task in qualityTestStreamReceiveTasks.values {
            task.cancel()
        }
        qualityTestStreamReceiveTasks.removeAll()
        if let hostSupportLogArchiveContinuation {
            self.hostSupportLogArchiveContinuation = nil
            hostSupportLogArchiveRequestID = nil
            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = nil
            hostSupportLogArchiveTimeoutTask?.cancel()
            hostSupportLogArchiveTimeoutTask = nil
            hostSupportLogArchiveContinuation.resume(throwing: CancellationError())
        }
        if let hostWallpaperContinuation {
            self.hostWallpaperContinuation = nil
            hostWallpaperRequestID = nil
            hostWallpaperTimeoutTask?.cancel()
            hostWallpaperTimeoutTask = nil
            hostWallpaperContinuation.resume(throwing: CancellationError())
        }
        hasCompletedBootstrap = false
        negotiatedFeatures = []
        mediaPayloadEncryptionEnabled = true
        if let desktopStreamID {
            clearDesktopResizeState(streamID: desktopStreamID)
        } else {
            desktopResizeCoordinator.clearAllState()
        }
        desktopStreamID = nil
        desktopStreamResolution = nil
        desktopStreamMode = nil
        desktopCursorPresentation = nil
        connectionState = state
        await refreshSharedClipboardBridgeState()

        if notifyDelegate {
            delegate?.clientService(self, didDisconnectFromHost: reason)
        }
    }

    private func connectBootstrappedControlSession(
        to host: LoomPeer,
        hello: LoomSessionHelloRequest,
        attemptID: UUID
    ) async throws -> BootstrappedControlSession {
        try throwIfConnectAttemptIsStale(attemptID)

        let attempts = controlSessionAttempts(for: host)
        var lastFailureReason: String?

        for (attemptIndex, attempt) in attempts.enumerated() {
            try throwIfConnectAttemptIsStale(attemptID)

            var openedSession: LoomAuthenticatedSession?
            var openedChannel: MirageControlChannel?

            do {
                let session = try await establishControlSession(
                    attempt: attempt,
                    hello: hello,
                    attemptID: attemptID
                )
                openedSession = session
                let controlChannel = try await MirageControlChannel.open(on: session)
                openedChannel = controlChannel
                try Task.checkCancellation()
                try throwIfConnectAttemptIsStale(attemptID)
                try await performBootstrap(over: controlChannel, provisionalHost: host)
                try Task.checkCancellation()
                try throwIfConnectAttemptIsStale(attemptID)
                return BootstrappedControlSession(session: session, controlChannel: controlChannel)
            } catch {
                if let openedChannel {
                    await openedChannel.cancel()
                } else if let openedSession {
                    await openedSession.cancel()
                }

                let classification = Self.classifyControlSessionFailure(error)
                if error is CancellationError || classification == .cancelled {
                    throw error
                }

                let failureReason = Self.bootstrappedControlSessionFailureReason(
                    for: attempt,
                    classification: classification,
                    underlyingError: error
                )
                lastFailureReason = failureReason

                if Self.shouldRetryLaterControlSessionAttempt(
                    classification: classification,
                    attempts: attempts,
                    currentAttemptIndex: attemptIndex
                ) {
                    MirageLogger.client("\(failureReason); retrying over next advertised transport")
                    continue
                }

                if let networkMismatchReason = Self.localNetworkMismatchReason(
                    for: host,
                    classification: classification,
                    localNetwork: localNetworkMonitor.snapshot()
                ) {
                    MirageLogger.client(
                        "Bootstrap failure diagnosed as local-network mismatch: \(failureReason)"
                    )
                    throw MirageError.protocolError(networkMismatchReason)
                }

                throw MirageError.protocolError(failureReason)
            }
        }

        throw MirageError.protocolError(
            lastFailureReason ?? "Failed to bootstrap control session to \(host.name)"
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
        let bootstrapProgressTracker = ConnectSessionBootstrapProgressTracker()
        let connectTask = Task<LoomAuthenticatedSession, Error> { [weak self] in
            let session = try await node.connect(
                to: attempt.endpoint,
                using: attempt.transportKind,
                hello: hello,
                requiredInterfaceType: attempt.requiredInterfaceType,
                onTrustPending: { @MainActor [weak self] in
                    self?.isAwaitingManualApproval = true
                },
                onBootstrapProgress: { [weak self] progress in
                    Task {
                        await bootstrapProgressTracker.record(progress)
                        await MainActor.run {
                            self?.handleConnectBootstrapProgress(
                                progress,
                                attempt: attempt,
                                attemptID: attemptID
                            )
                        }
                    }
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
                attempt: attempt,
                attemptID: attemptID,
                timeout: controlSessionConnectTimeout(for: attempt),
                bootstrapProgressTracker: bootstrapProgressTracker
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
        attempt: ControlSessionAttempt,
        attemptID: UUID,
        timeout: Duration,
        bootstrapProgressTracker: ConnectSessionBootstrapProgressTracker
    ) async throws -> LoomAuthenticatedSession {
        let timeoutError = MirageError.timeout
        var connectResultTask: Task<Void, Never>?
        var timeoutMonitorTask: Task<Void, Never>?

        defer {
            connectResultTask?.cancel()
            timeoutMonitorTask?.cancel()
        }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = ConnectSessionContinuationBox(continuation)

                connectResultTask = Task {
                    do {
                        let session = try await connectTask.value
                        await box.resume(returning: session)
                    } catch {
                        await box.resume(throwing: error)
                    }
                }

                // Cancel the watchdog loop as soon as this race resolves so
                // repeated fallback attempts do not accumulate idle timers.
                timeoutMonitorTask = Task { [timeout, timeoutError] in
                    let absoluteTimeout = absoluteControlSessionConnectTimeout(for: attempt)
                    let trustPendingTimeout = max(
                        absoluteTimeout,
                        trustPendingControlSessionConnectTimeout
                    )

                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        let timedOut = await bootstrapProgressTracker.shouldTimeOut(
                            now: ContinuousClock.now,
                            initialTimeout: timeout,
                            activePhaseIdleTimeout: timeout,
                            trustPendingIdleTimeout: trustPendingTimeout,
                            absoluteTimeout: absoluteTimeout,
                            trustPendingAbsoluteTimeout: trustPendingTimeout
                        )
                        guard timedOut else { continue }
                        connectTask.cancel()
                        await box.resume(throwing: timeoutError)
                        return
                    }
                }
            }
        } catch {
            if isCurrentConnectAttempt(attemptID) {
                cancelPendingConnectTask(attemptID: attemptID)
            }
            throw error
        }
    }

    private func controlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.transportKind == .udp {
            return .seconds(5)
        }
        return controlSessionConnectTimeout
    }

    private func absoluteControlSessionConnectTimeout(for attempt: ControlSessionAttempt) -> Duration {
        if attempt.transportKind == .udp {
            return .seconds(20)
        }
        return controlSessionConnectTimeout(for: attempt)
    }

    private func handleConnectBootstrapProgress(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        attempt: ControlSessionAttempt,
        attemptID: UUID
    ) {
        guard isCurrentConnectAttempt(attemptID) else { return }

        if progress.phase == .remoteHelloReceived || progress.phase == .trustPendingApproval {
            if case .connecting = connectionState {
                connectionState = .handshaking(host: attempt.hostName)
            }
        }

        if let failureReason = progress.failureReason {
            MirageLogger.client(
                "Pre-bootstrap \(attempt.transportKind.rawValue) control session failed at " +
                    "\(progress.phase.rawValue) for \(attempt.hostName): \(failureReason)"
            )
            return
        }

        MirageLogger.client(
            "Pre-bootstrap \(attempt.transportKind.rawValue) progress for \(attempt.hostName): \(progress.phase.rawValue)"
        )
    }

    func controlSessionAttempts(for host: LoomPeer) -> [ControlSessionAttempt] {
        let requiredInterfaceType = preferredNetworkType.requiredInterfaceType
        var attempts: [ControlSessionAttempt] = []

        for transportKind in [LoomTransportKind.udp, .quic, .tcp] {
            guard let endpoint = controlSessionEndpoint(for: host, transportKind: transportKind) else {
                continue
            }

            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: endpoint,
                    transportKind: transportKind,
                    requiredInterfaceType: requiredInterfaceType
                )
            )
        }

        if attempts.isEmpty {
            attempts.append(
                ControlSessionAttempt(
                    hostName: host.name,
                    endpoint: host.endpoint,
                    transportKind: .tcp,
                    requiredInterfaceType: requiredInterfaceType
                )
            )
        }

        return attempts
    }

    private func controlSessionEndpoint(
        for host: LoomPeer,
        transportKind: LoomTransportKind
    ) -> NWEndpoint? {
        guard let transport = host.advertisement.directTransports.first(where: { $0.transportKind == transportKind }),
              let port = NWEndpoint.Port(rawValue: transport.port) else {
            if transportKind == .tcp {
                return host.endpoint
            }
            return nil
        }

        let endpointHost = endpointHost(for: host.endpoint)
        let selectedHost: NWEndpoint.Host?
        switch transportKind {
        case .udp:
            selectedHost = controlSessionUDPHost(for: host, endpointHost: endpointHost)
        case .quic, .tcp:
            if let endpointHost, shouldPreferEndpointHostForDirectConnection(endpointHost) {
                selectedHost = endpointHost
            } else {
                selectedHost = controlSessionUDPHost(for: host, endpointHost: endpointHost)
            }
        }

        guard let selectedHost else { return nil }
        return .hostPort(host: selectedHost, port: port)
    }

    private func controlSessionUDPHost(for host: LoomPeer) -> NWEndpoint.Host? {
        controlSessionUDPHost(for: host, endpointHost: endpointHost(for: host.endpoint))
    }

    private func controlSessionUDPHost(
        for host: LoomPeer,
        endpointHost: NWEndpoint.Host?
    ) -> NWEndpoint.Host? {
        // Prefer Bonjour-resolved IP addresses over hostname resolution.
        // This avoids platform-specific mDNS resolution failures (iOS) and
        // ensures we don't accidentally route through VPN/overlay interfaces
        // when a local path exists.
        if !host.resolvedAddresses.isEmpty {
            let localAddresses = host.resolvedAddresses.filter { !Self.isOverlayAddress($0) }
            if let preferred = localAddresses.first {
                return preferred
            }
            // All resolved addresses are overlay — use the first one anyway
            // since it's still better than an unresolvable hostname.
            if let fallback = host.resolvedAddresses.first {
                return fallback
            }
        }

        if let endpointHost, shouldPreferEndpointHostForDirectConnection(endpointHost) {
            return endpointHost
        }

        if let rememberedHost = rememberedDirectEndpointHostByDeviceID[host.deviceID],
           shouldPreferEndpointHostForDirectConnection(rememberedHost) {
            return rememberedHost
        }

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

    /// Returns `true` when the host is an overlay/VPN address (e.g. Tailscale CGNAT).
    private static func isOverlayAddress(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let addr):
            // Tailscale uses 100.64.0.0/10 (CGNAT range).
            let raw = addr.rawValue
            guard raw.count >= 4 else { return false }
            return raw[raw.startIndex] == 100 && (raw[raw.startIndex.advanced(by: 1)] & 0xC0) == 64
        case .ipv6(let addr):
            // Tailscale IPv6: fd7a:115c:a1e0::/48
            let raw = addr.rawValue
            guard raw.count >= 6 else { return false }
            return raw[raw.startIndex] == 0xfd
                && raw[raw.startIndex.advanced(by: 1)] == 0x7a
                && raw[raw.startIndex.advanced(by: 2)] == 0x11
                && raw[raw.startIndex.advanced(by: 3)] == 0x5c
                && raw[raw.startIndex.advanced(by: 4)] == 0xa1
                && raw[raw.startIndex.advanced(by: 5)] == 0xe0
        default:
            return false
        }
    }

    private func endpointHost(for endpoint: NWEndpoint) -> NWEndpoint.Host? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return host
    }

    private func shouldPreferEndpointHostForDirectConnection(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4, .ipv6:
            return true
        case .name(let value, _):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            return normalized.hasSuffix(".local") == false
        @unknown default:
            return false
        }
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

    internal struct ControlSessionNetworkDiagnostics: Sendable, Equatable {
        let currentPathKind: MirageNetworkPathKind
        let wifiSubnetSignatures: [String]
        let wiredSubnetSignatures: [String]

        var allSubnetSignatures: Set<String> {
            Set(wifiSubnetSignatures).union(wiredSubnetSignatures)
        }
    }

    internal enum ControlSessionFailureClassification: String {
        case timeout
        case transportLoss
        case connectionRefused
        case addressUnavailable
        case cancelled
        case other

        var shouldRetryLaterDirectAttempt: Bool {
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
            case let .protocolError(reason):
                if looksLikeAddressResolutionFailure(reason) {
                    return .addressUnavailable
                }
                if looksLikeBootstrapResponseTimeout(reason) {
                    return .timeout
                }
                if looksLikeBootstrapTransportFailure(reason) {
                    return .transportLoss
                }
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
            case let .protocolError(reason):
                if looksLikeAddressResolutionFailure(reason) {
                    return .addressUnavailable
                }
                if looksLikeBootstrapResponseTimeout(reason) {
                    return .timeout
                }
                if looksLikeBootstrapTransportFailure(reason) {
                    return .transportLoss
                }
            case let .connectionFailed(underlyingError):
                if let failure = underlyingError as? LoomConnectionFailure {
                    return classifyLoomConnectionFailure(failure)
                }
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

    internal static func shouldRetryLaterControlSessionAttempt(
        classification: ControlSessionFailureClassification,
        attempts: [ControlSessionAttempt],
        currentAttemptIndex: Int
    ) -> Bool {
        guard classification.shouldRetryLaterDirectAttempt else {
            return false
        }
        return attempts.indices.contains(currentAttemptIndex + 1)
    }

    private static func looksLikeAddressResolutionFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("failed to resolve") ||
            normalized.contains("nodename nor servname provided") ||
            normalized.contains("name or service not known")
    }

    private static func looksLikeBootstrapResponseTimeout(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("timed out waiting for host bootstrap response")
    }

    private static func looksLikeBootstrapTransportFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("control stream closed before receiving bootstrap response") ||
            normalized.contains("authenticated loom session closed before mirage control stream opened")
    }

    private static func classifyLoomConnectionFailure(
        _ failure: LoomConnectionFailure
    ) -> ControlSessionFailureClassification {
        switch failure.reason {
        case .timedOut:
            .timeout
        case .transportLoss, .closed:
            .transportLoss
        case .connectionRefused:
            .connectionRefused
        case .addressUnavailable:
            .addressUnavailable
        case .cancelled:
            .cancelled
        case .other:
            .other
        }
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

    internal static func bootstrappedControlSessionFailureReason(
        for attempt: ControlSessionAttempt,
        classification: ControlSessionFailureClassification,
        underlyingError: Error
    ) -> String {
        "Mirage bootstrap failed for \(attempt.hostName) endpoint=\(attempt.endpoint) " +
            "transport=\(attempt.transportKind.rawValue) interface=\(attempt.interfaceDescription) " +
            "classification=\(classification.rawValue) error=\(underlyingError.localizedDescription)"
    }

    internal static func localNetworkMismatchReason(
        for host: LoomPeer,
        classification: ControlSessionFailureClassification,
        localNetwork: MirageLocalNetworkSnapshot
    ) -> String? {
        localNetworkMismatchReason(
            for: host,
            classification: classification,
            localNetwork: ControlSessionNetworkDiagnostics(
                currentPathKind: localNetwork.currentPathKind,
                wifiSubnetSignatures: localNetwork.wifiSubnetSignatures,
                wiredSubnetSignatures: localNetwork.wiredSubnetSignatures
            )
        )
    }

    internal static func localNetworkMismatchReason(
        for host: LoomPeer,
        classification: ControlSessionFailureClassification,
        localNetwork: ControlSessionNetworkDiagnostics
    ) -> String? {
        switch classification {
        case .timeout, .transportLoss, .addressUnavailable:
            break
        case .connectionRefused, .cancelled, .other:
            return nil
        }

        let hostNetwork = MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(
            from: host.advertisement
        )
        guard localNetwork.currentPathKind != .awdl,
              !localNetwork.allSubnetSignatures.isEmpty,
              !hostNetwork.allSubnetSignatures.isEmpty else {
            return nil
        }

        let localWiFi = Set(localNetwork.wifiSubnetSignatures)
        let localWired = Set(localNetwork.wiredSubnetSignatures)
        let hostWiFi = Set(hostNetwork.wifiSubnetSignatures)
        let hostWired = Set(hostNetwork.wiredSubnetSignatures)
        let anyOverlap = !localNetwork.allSubnetSignatures.intersection(hostNetwork.allSubnetSignatures).isEmpty

        switch localNetwork.currentPathKind {
        case .wifi:
            if !localWiFi.isEmpty,
               !hostWiFi.isEmpty,
               localWiFi.intersection(hostWiFi).isEmpty {
                return "The host and client appear to be on different Wi-Fi networks. Connect both devices to the same Wi-Fi network or re-enable peer-to-peer."
            }
            if !anyOverlap {
                return "The host and client appear to be on different local networks. Connect both devices to the same LAN or re-enable peer-to-peer."
            }
        case .wired:
            if !localWired.isEmpty,
               localWired.intersection(hostNetwork.allSubnetSignatures).isEmpty {
                return "The host and client do not appear to be on the same wired network. Check that both devices are on the same subnet or VLAN."
            }
        case .cellular, .loopback, .other, .unknown, .awdl:
            break
        }

        return nil
    }

    private static func classifyNetworkFailure(_ error: NWError) -> ControlSessionFailureClassification {
        switch error {
        case let .posix(code):
            return classifyPOSIXError(code)
        case .dns:
            return .addressUnavailable
        case .tls:
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

    private func rememberDirectEndpointHost(_ endpoint: NWEndpoint?, for deviceID: UUID) {
        guard let endpoint else { return }
        guard case let .hostPort(host, _) = endpoint else { return }
        guard shouldPreferEndpointHostForDirectConnection(host) else { return }
        rememberedDirectEndpointHostByDeviceID[deviceID] = host
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
        let serviceBox = WeakSendableBox(self)
        controlSessionStateObserverTask = Task.detached(priority: .userInitiated) { [session, serviceBox] in
            let observer = await session.makeStateObserver()
            for await state in observer {
                guard !Task.isCancelled else { break }
                guard let service = serviceBox.value else { break }
                guard await service.isCurrentLoomSession(sessionID: session.id) else { break }
                await service.logObservedControlSessionState(state, sessionID: session.id)
                switch state {
                case let .failed(reason):
                    await service.handleDisconnect(
                        reason: reason,
                        state: .error(reason),
                        notifyDelegate: service.hasCompletedBootstrap
                    )
                case .cancelled:
                    await service.handleDisconnect(
                        reason: "Connection cancelled",
                        state: .disconnected,
                        notifyDelegate: service.hasCompletedBootstrap
                    )
                default:
                    continue
                }
                break
            }
        }

        controlSessionPathObserverTask?.cancel()
        controlSessionPathObserverTask = Task.detached(priority: .userInitiated) { [session, serviceBox] in
            let observer = await session.makePathObserver()
            for await pathSnapshot in observer {
                guard !Task.isCancelled else { break }
                guard let service = serviceBox.value else { break }
                guard await service.isCurrentLoomSession(sessionID: session.id) else { break }
                let snapshot = MirageNetworkPathClassifier.classify(pathSnapshot)
                await service.logObservedControlPathUpdate(snapshot, sessionID: session.id)
                await service.handleControlPathUpdate(snapshot)
            }
        }
    }

    private func logObservedControlSessionState(
        _ state: LoomAuthenticatedSessionState,
        sessionID: UUID
    ) {
        MirageLogger.client("Control session state observed: session=\(sessionID.uuidString) state=\(state)")
    }

    private func logObservedControlPathUpdate(
        _ snapshot: MirageNetworkPathSnapshot,
        sessionID: UUID
    ) {
        MirageLogger.client(
            "Control path updated: session=\(sessionID.uuidString) \(snapshot.signature)"
        )
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

actor ConnectSessionBootstrapProgressTracker {
    private let startedAt = ContinuousClock.now
    private var latestProgress = LoomAuthenticatedSessionBootstrapProgress(phase: .idle)
    private var lastProgressAt = ContinuousClock.now

    func record(
        _ progress: LoomAuthenticatedSessionBootstrapProgress,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        guard progress != latestProgress else { return }
        latestProgress = progress
        lastProgressAt = now
    }

    func shouldTimeOut(
        now: ContinuousClock.Instant,
        initialTimeout: Duration,
        activePhaseIdleTimeout: Duration,
        trustPendingIdleTimeout: Duration,
        absoluteTimeout: Duration,
        trustPendingAbsoluteTimeout: Duration
    ) -> Bool {
        if latestProgress.phase == .ready || latestProgress.isFailure {
            return false
        }

        let idleTimeout: Duration
        let resolvedAbsoluteTimeout: Duration

        switch latestProgress.phase {
        case .idle:
            idleTimeout = initialTimeout
            resolvedAbsoluteTimeout = absoluteTimeout
        case .trustPendingApproval:
            idleTimeout = trustPendingIdleTimeout
            resolvedAbsoluteTimeout = trustPendingAbsoluteTimeout
        default:
            idleTimeout = activePhaseIdleTimeout
            resolvedAbsoluteTimeout = absoluteTimeout
        }

        if now - startedAt >= resolvedAbsoluteTimeout {
            return true
        }

        if latestProgress.phase == .idle {
            return now - startedAt >= idleTimeout
        }
        return now - lastProgressAt >= idleTimeout
    }
}
