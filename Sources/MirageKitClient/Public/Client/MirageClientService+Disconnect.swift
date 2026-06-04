//
//  MirageClientService+Disconnect.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import Network
import MirageKit

@MainActor
extension MirageClientService {
    /// Enqueues a disconnect notice without waiting for acknowledgement.
    public func queueDisconnectNoticeBestEffort() {
        _ = sendControlMessageBestEffort(
            .disconnect,
            content: DisconnectMessage(reason: .userRequested)
        )
    }

    func sendDisconnectNoticeBeforeTeardown(over controlChannel: MirageControlChannel) async {
        let waiter = MirageDisconnectNoticeWaiter()
        let sendTask = Task {
            do {
                try await controlChannel.send(
                    .disconnect,
                    content: DisconnectMessage(reason: .userRequested)
                )
                do {
                    try await controlChannel.closeStream()
                } catch {
                    MirageLogger.error(.client, error: error, message: "Failed to close control channel after disconnect notice: ")
                }
            } catch {
                // Disconnect is already in progress. Continue local teardown even if
                // the peer closed the control channel before it could receive notice.
            }
            waiter.complete()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            waiter.complete()
        }

        await waiter.wait()
        sendTask.cancel()
        timeoutTask.cancel()
    }

    func sendDisconnectNoticeInBackgroundBeforeTransportCancel(
        over controlChannel: MirageControlChannel
    ) {
        Task { @MainActor in
            await sendDisconnectNoticeBeforeTeardown(over: controlChannel)
            await controlChannel.cancel()
        }
    }

    func handleDisconnect(
        reason: String,
        state: ConnectionState,
        notifyDelegate: Bool,
        forceCleanup: Bool = false,
        cancelTransport: Bool = true
    ) async {
        if case .disconnected = connectionState, !forceCleanup {
            return
        }

        if case .error = connectionState, !forceCleanup {
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
        let disconnectDiagnostics = controlDisconnectDiagnostics(
            reason: reason,
            activeStreams: sessions
        )
        MirageLogger.client("Control disconnect diagnostics: \(disconnectDiagnostics)")

        controlChannel = nil
        loomSession = nil
        transferEngine = nil
        stopTransferObserver()
        lastDisconnectReason = reason
        connectionState = state

        if cancelTransport {
            if let disconnectedControlChannel {
                Task {
                    await disconnectedControlChannel.cancel()
                }
            } else {
                Task {
                    await disconnectedLoomSession?.cancel()
                }
            }
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
        inputEventSender.updatePriorityRoute(nil)
        inputEventSender.updateSendHandler(nil)
        expectedHostIdentityKeyID = nil
        connectedHostIdentityKeyID = nil
        connectedHostIdentity = nil
        connectedHostAllowsRemoteAccess = nil
        setMediaSecurityContext(nil)
        receiveBuffer = Data()
        stopHeartbeat()
        fastPathState.resetInboundActivity()
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        activeAppListRequestID = nil
        activeAppListReceivedBundleIdentifiers.removeAll(keepingCapacity: false)
        availableAppsByBundleIdentifier.removeAll(keepingCapacity: false)
        orderedAvailableAppBundleIdentifiers.removeAll(keepingCapacity: false)
        deferredControlRefreshRequirements = .none
        setControlUpdatePolicy(.normal)
        streamingAppBundleID = nil
        for session in sessions {
            if session.kind == .custom {
                await stopCustomStream(session)
            } else {
                await stopViewing(session)
            }
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
        for continuation in customStreamStartedContinuations.values {
            continuation.resume(throwing: MirageError.protocolError(reason))
        }
        customStreamStartedContinuations.removeAll()
        customStreamDescriptorsByStreamID.removeAll()
        registeredStreamIDs.removeAll()
        lastKeyframeRequestTime.removeAll()
        receiverMediaFeedbackLastSendTime.removeAll()
        receiverMediaFeedbackLastIncompleteFrameTimeouts.removeAll()
        receiverMediaFeedbackLastForwardGapTimeouts.removeAll()
        receiverMediaFeedbackLastMissingFragmentTimeouts.removeAll()
        receiverMediaFeedbackSequence = 0
        cancelDesktopStreamStopTimeout()
        retiredDesktopSessionIDs.removeAll()
        pendingApplicationActivationRecoveryStreamIDs.removeAll()
        desktopStreamRequestStartTime = 0
        lastDesktopStreamStartRequest = nil
        desktopStreamRestartAttempts = 0
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = nil
        appStreamStartTimeoutTask?.cancel()
        appStreamStartTimeoutTask = nil
        pendingStreamSetupRequestID = nil
        pendingStreamSetupKind = nil
        pendingStreamSetupAppSessionID = nil
        streamStartupBaseTimes.removeAll()
        streamStartupFirstRegistrationSent.removeAll()
        streamStartupFirstPacketReceived.removeAll()
        clearControlPathState()
        resetRuntimeWorkloadSafetyState()
        decoderCompatibilityCurrentColorDepthByStream.removeAll()
        decoderCompatibilityBaselineColorDepthByStream.removeAll()
        pendingRequestedColorDepthByWindowID.removeAll()
        pendingDesktopRequestedColorDepth = nil
        pendingAppRequestedColorDepth = nil
        pendingDesktopRequestedLatencyMode = nil
        pendingAppRequestedLatencyMode = nil
        pendingStreamSetupLatencyMode = nil
        renderLatencyModeByStream.removeAll()
        desktopDimensionTokenByStream.removeAll()
        appDimensionTokenByStream.removeAll()
        appStreamStartAcknowledgementByStreamID.removeAll()
        appWindowResizeResultByStreamID.removeAll()
        appStreamPlaceholderDesktopStreamID = nil
        appStreamPlaceholderAppSessionID = nil
        appAtlasLayoutsByMediaStreamID.removeAll()
        fastPathState.clearAllStartupPacketPending()
        fastPathState.clearDiagnostics()
        for task in startupRegistrationRetryTasks.values {
            task.cancel()
        }
        startupRegistrationRetryTasks.removeAll()
        for task in postResizeTransitionTimeoutTasks.values {
            task.cancel()
        }
        postResizeTransitionTimeoutTasks.removeAll()
        activeStreams.removeAll()
        for session in storedSessions {
            sessionStore.removeSession(session.id)
        }
        await updateReassemblerSnapshot()

        fastPathState.clearActiveStreamIDs()

        hostSessionState = nil
        currentSessionToken = nil
        authorizationState = .idle
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
        fastPathState.clearQualityTestAccumulator()
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
        mediaPayloadEncryptionEnabled = true
        #if os(iOS) || os(visionOS)
        Self.clearCachedDisplayMetrics()
        #endif
        if let desktopStreamID {
            clearDesktopResizeState(streamID: desktopStreamID)
        } else {
            desktopResizeCoordinator.clearAllState()
        }
        desktopStreamID = nil
        desktopSessionID = nil
        desktopStreamResolution = nil
        desktopStreamPresentationResolution = nil
        desktopStreamDisplayScaleFactor = nil
        desktopCaptureSource = .virtualDisplay
        desktopStreamAllowsClientResize = true
        desktopStreamMode = nil
        desktopCursorPresentation = nil
        connectionState = state
        await refreshSharedClipboardBridgeState()

        if notifyDelegate {
            delegate?.didDisconnectFromHost(reason)
        }
    }

    func controlDisconnectDiagnostics(
        reason: String,
        activeStreams: [ClientStreamSession]
    ) -> String {
        let now = CFAbsoluteTimeGetCurrent()
        let latestInboundActivityTime = fastPathState.latestInboundActivityTime
        let inboundAgeMs = latestInboundActivityTime > 0
            ? Int(max(0, now - latestInboundActivityTime) * 1000)
            : -1
        let pathStatus = currentControlPathStatus
        let interfaces = pathStatus?.interfaceSummary ?? "unknown"
        let localEndpoint = pathStatus?.localEndpointDescription ?? "unknown"
        let remoteEndpoint = pathStatus?.remoteEndpointDescription ?? "unknown"
        let streamIDs = activeStreams
            .map(\.id)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        let mediaStreamIDs = activeStreams
            .map(\.mediaStreamID)
            .sorted()
            .map(String.init)
            .joined(separator: ",")

        return [
            "reason=\(reason)",
            "path=\(pathStatus?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue)",
            "interfaces=\(interfaces)",
            "local=\(localEndpoint)",
            "remote=\(remoteEndpoint)",
            "lastInboundAgeMs=\(inboundAgeMs)",
            "lastOutboundAgeMs=unavailable",
            "pendingAckAgeMs=unavailable",
            "connectionState=\(Self.controlDisconnectConnectionStateName(connectionState))",
            "bootstrapComplete=\(hasCompletedBootstrap)",
            "activeStreamIDs=[\(streamIDs)]",
            "activeMediaStreamIDs=[\(mediaStreamIDs)]",
            "desktopStreamID=\(desktopStreamID.map(String.init) ?? "nil")",
        ].joined(separator: " ")
    }

    static func controlDisconnectConnectionStateName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .handshaking:
            "handshaking"
        case .connected:
            "connected"
        case .reconnecting:
            "reconnecting"
        case .error:
            "error"
        }
    }

    func installInputSendHandler(controlChannel: MirageControlChannel) async {
        let transportKind = await controlChannel.session.context?.transportKind
        let fallbackSender: @Sendable (Data, MirageInputEventSender.DeliveryMode) async throws -> Void = {
            [weak controlChannel, transportKind] data, deliveryMode in
            guard let controlChannel else {
                throw MirageError.protocolError("Control channel unavailable")
            }
            if deliveryMode == .droppableRealtime,
               transportKind == .udp || transportKind == .quic {
                try await controlChannel.sendSerializedUnreliable(data)
                return
            }
            try await controlChannel.sendSerialized(data)
        }
        inputEventSender.updateSendHandler(fallbackSender)

        guard await shouldEnablePriorityInputLane(for: controlChannel) else {
            inputEventSender.updatePriorityRoute(nil)
            return
        }

        do {
            let endpoint = try await controlChannel.session.makePriorityInputEndpoint()
            let route = MiragePriorityInputClientRoute(
                endpoint: endpoint,
                fallbackSender: fallbackSender
            )
            inputEventSender.updatePriorityRoute(route)
            MirageLogger.client("Priority input lane enabled on local datagram control session")
        } catch {
            inputEventSender.updatePriorityRoute(nil)
            MirageLogger.client(
                "Priority input lane unavailable; using control input fallback: \(error.localizedDescription)"
            )
        }
    }

    private func shouldEnablePriorityInputLane(for controlChannel: MirageControlChannel) async -> Bool {
        guard !MirageLatencyOptions.disablePriorityInput() else {
            return false
        }
        let transportKind = await controlChannel.session.context?.transportKind
        guard transportKind == .udp || transportKind == .quic else {
            return false
        }
        // Keep priority input on local/proximity paths until remote congestion
        // and path-health behavior are validated.
        guard let pathSnapshot = await controlChannel.session.pathSnapshot else {
            return isLocalEndpoint(await controlChannel.session.remoteEndpoint)
        }

        let usesLocalInterface = pathSnapshot.usesWiFi ||
            pathSnapshot.usesWiredEthernet ||
            pathSnapshot.usesLoopback ||
            pathSnapshot.interfaceNames.contains(where: Self.isLocalProximityInterfaceName(_:))
        guard usesLocalInterface else { return false }
        return isLocalEndpoint(await controlChannel.session.remoteEndpoint ?? pathSnapshot.remoteEndpoint)
    }

    private static func isLocalProximityInterfaceName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("anpi") ||
            normalized.hasPrefix("apni") ||
            normalized.hasPrefix("awdl") ||
            normalized.hasPrefix("llw") ||
            normalized.hasPrefix("bridge")
    }

    private func isLocalEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let normalized = "\(host)".lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" { return true }
        if normalized.contains(".local") { return true }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("[fe80:") { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("[fc") { return true }
        if normalized.hasPrefix("fd") || normalized.hasPrefix("[fd") { return true }
        let tokens = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 4,
              let first = UInt8(tokens[0]),
              let second = UInt8(tokens[1]) else {
            return false
        }
        if first == 127 { return true }
        if first == 10 { return true }
        if first == 192, second == 168 { return true }
        if first == 172, (16 ... 31).contains(second) { return true }
        if first == 169, second == 254 { return true }
        return false
    }
}
