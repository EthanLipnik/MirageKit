//
//  MirageClientService+MessageHandling+Core.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Core control message handling.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func protocolMismatchInfo(from response: HelloResponseMessage) -> ProtocolMismatchInfo? {
        guard response.rejectionReason == .protocolVersionMismatch else {
            return nil
        }
        return ProtocolMismatchInfo(
            reason: mapProtocolMismatchReason(response.rejectionReason),
            hostProtocolVersion: response.protocolMismatchHostVersion,
            clientProtocolVersion: response.protocolMismatchClientVersion,
            hostUpdateTriggerAccepted: response.protocolMismatchUpdateTriggerAccepted,
            hostUpdateTriggerMessage: response.protocolMismatchUpdateTriggerMessage
        )
    }

    func mapProtocolMismatchReason(_ reason: HelloRejectionReason?) -> ProtocolMismatchInfo.Reason {
        switch reason {
        case .protocolVersionMismatch:
            return .protocolVersionMismatch
        case .protocolFeaturesMismatch:
            return .protocolFeaturesMismatch
        case .hostBusy:
            return .hostBusy
        case .rejected:
            return .rejected
        case .unauthorized:
            return .unauthorized
        case .none:
            return .unknown
        }
    }

    func helloRejectionDescription(
        for response: HelloResponseMessage,
        mismatchInfo: ProtocolMismatchInfo?
    ) -> String {
        if let mismatchInfo {
            let hostVersion = mismatchInfo.hostProtocolVersion.map(String.init) ?? "unknown"
            let clientVersion = mismatchInfo.clientProtocolVersion.map(String.init) ?? "unknown"
            return "Protocol mismatch (host \(hostVersion), client \(clientVersion))."
        }

        switch response.rejectionReason {
        case .protocolFeaturesMismatch:
            return "Protocol feature mismatch."
        case .hostBusy:
            return "Host is already connected to another client."
        case .unauthorized:
            return "Connection rejected by host authorization policy."
        case .rejected:
            return "Connection rejected by host."
        case .protocolVersionMismatch:
            return "Protocol mismatch."
        case .none:
            return "Connection rejected."
        }
    }

    func handleHelloResponse(_ message: ControlMessage) async {
        do {
            let response = try message.decode(HelloResponseMessage.self)
            guard let pendingHelloNonce else {
                connectionState = .error("Invalid handshake state")
                MirageLogger.client("Rejected hello response without pending nonce")
                return
            }
            let helloNonce = pendingHelloNonce
            guard response.requestNonce == pendingHelloNonce else {
                connectionState = .error("Invalid handshake nonce")
                MirageLogger.client("Rejected hello response with mismatched nonce")
                return
            }

            let identity = response.identity
            guard identity.keyID == MirageIdentityManager.keyID(for: identity.publicKey) else {
                connectionState = .error("Invalid host identity key")
                MirageLogger.client("Rejected hello response with invalid host key ID")
                return
            }
            let replayValid = await handshakeReplayProtector.validate(
                timestampMs: identity.timestampMs,
                nonce: identity.nonce
            )
            guard replayValid else {
                connectionState = .error("Replay detected")
                MirageLogger.client("Rejected hello response due to replay protection")
                return
            }
            let signedPayload = try MirageIdentitySigning.helloResponsePayload(
                accepted: response.accepted,
                hostID: response.hostID,
                hostName: response.hostName,
                requiresAuth: response.requiresAuth,
                dataPort: response.dataPort,
                negotiation: response.negotiation,
                requestNonce: response.requestNonce,
                mediaEncryptionEnabled: response.mediaEncryptionEnabled,
                udpRegistrationToken: response.udpRegistrationToken,
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
                connectionState = .error("Host signature invalid")
                MirageLogger.client("Rejected hello response with invalid host signature")
                return
            }
            if let expectedHostIdentityKeyID, expectedHostIdentityKeyID != identity.keyID {
                connectionState = .error("Host identity mismatch")
                MirageLogger.client(
                    "Rejected hello response due to host key mismatch expected=\(expectedHostIdentityKeyID) actual=\(identity.keyID)"
                )
                return
            }

            connectedHostIdentityKeyID = identity.keyID
            self.pendingHelloNonce = nil
            hasReceivedHelloResponse = true
            isAwaitingManualApproval = false
            approvalWaitTask?.cancel()
            if response.accepted {
                guard response.mediaEncryptionEnabled else {
                    connectionState = .error("Host media encryption disabled")
                    MirageLogger.client("Rejected hello response with media encryption disabled")
                    return
                }
                guard response.udpRegistrationToken.count == MirageMediaSecurity.registrationTokenLength else {
                    connectionState = .error("Invalid UDP registration token")
                    MirageLogger.client(
                        "Rejected hello response due to invalid UDP registration token length \(response.udpRegistrationToken.count)"
                    )
                    return
                }
                let resolvedIdentityManager = identityManager ?? MirageIdentityManager.shared
                let localIdentity: MirageAccountIdentity
                do {
                    localIdentity = try resolvedIdentityManager.currentIdentity()
                } catch {
                    connectionState = .error("Missing local identity")
                    MirageLogger.client("Failed to load local identity for media key derivation: \(error)")
                    return
                }
                let mediaContext: MirageMediaSecurityContext
                do {
                    mediaContext = try MirageMediaSecurity.deriveContext(
                        identityManager: resolvedIdentityManager,
                        peerPublicKey: identity.publicKey,
                        hostID: response.hostID,
                        clientID: deviceID,
                        hostKeyID: identity.keyID,
                        clientKeyID: localIdentity.keyID,
                        hostNonce: identity.nonce,
                        clientNonce: helloNonce,
                        udpRegistrationToken: response.udpRegistrationToken
                    )
                } catch {
                    connectionState = .error("Media key derivation failed")
                    MirageLogger.client("Rejected hello response due to media key derivation failure: \(error)")
                    return
                }

                setMediaSecurityContext(mediaContext)
                MirageLogger.client(
                    "Media security established (tokenBytes=\(mediaContext.udpRegistrationToken.count), keyBytes=\(mediaContext.sessionKey.count))"
                )
                if response.autoTrustGranted == true {
                    let hostComponent = response.hostID.uuidString.lowercased()
                    let noticeKey = "com.mirage.autotrust.client.\(hostComponent)"
                    let legacyNoticeKey = "com.mirage.autotrust.client.\(hostComponent).\(identity.keyID)"
                    if !UserDefaults.standard.bool(forKey: noticeKey),
                       !UserDefaults.standard.bool(forKey: legacyNoticeKey) {
                        UserDefaults.standard.set(true, forKey: noticeKey)
                        let hostDisplayName = response.hostName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if hostDisplayName.isEmpty {
                            onAutoTrustNotice?("Auto-approved trusted device for this host.")
                        } else {
                            onAutoTrustNotice?("Auto-approved trusted device for \(hostDisplayName).")
                        }
                    }
                }
                if response.negotiation.protocolVersion != Int(MirageKit.protocolVersion) {
                    connectionState = .error("Protocol version mismatch")
                    MirageLogger.client(
                        "Protocol mismatch host=\(response.negotiation.protocolVersion), client=\(MirageKit.protocolVersion)"
                    )
                    return
                }
                let requiredFeatures: MirageFeatureSet = [
                    .identityAuthV2,
                    .udpRegistrationAuthV1,
                    .encryptedMediaV1,
                ]
                guard response.negotiation.selectedFeatures.contains(requiredFeatures) else {
                    connectionState = .error("Protocol features mismatch")
                    MirageLogger.client(
                        "Rejected hello response missing required features \(response.negotiation.selectedFeatures)"
                    )
                    return
                }
                negotiatedFeatures = response.negotiation.selectedFeatures
                hostDataPort = response.dataPort
                MirageLogger.client("Received hello response, dataPort: \(hostDataPort)")
            } else {
                let mismatchInfo = protocolMismatchInfo(from: response)
                if let mismatchInfo {
                    onProtocolMismatch?(mismatchInfo)
                }
                let rejectionDescription = helloRejectionDescription(for: response, mismatchInfo: mismatchInfo)
                MirageLogger.client("Connection rejected by host: \(rejectionDescription)")
                connectionState = .error(rejectionDescription)
            }
        } catch {
            MirageLogger.error(.client, "Failed to decode hello response: \(error)")
        }
    }

    func handleWindowList(_ message: ControlMessage) {
        do {
            let windowList = try message.decode(WindowListMessage.self)
            MirageLogger.client("Received window list with \(windowList.windows.count) windows")
            for window in windowList.windows {
                MirageLogger.client("  - \(window.application?.name ?? "Unknown"): \(window.title ?? "Untitled")")
            }
            hasReceivedWindowList = true
            availableWindows = windowList.windows
            delegate?.clientService(self, didUpdateWindowList: windowList.windows)
        } catch {
            MirageLogger.error(.client, "Failed to decode window list: \(error)")
        }
    }

    func handleWindowUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(WindowUpdateMessage.self) {
            for window in update.added where !availableWindows.contains(where: { $0.id == window.id }) {
                availableWindows.append(window)
            }
            for id in update.removed {
                availableWindows.removeAll { $0.id == id }
            }
            for window in update.updated {
                if let index = availableWindows.firstIndex(where: { $0.id == window.id }) { availableWindows[index] = window }
            }
        }
    }

    func handleStreamStarted(_ message: ControlMessage) {
        if let started = try? message.decode(StreamStartedMessage.self) {
            let streamID = started.streamID
            MirageLogger.client("Stream started: \(streamID) for window \(started.windowID)")

            refreshRateOverridesByStream[streamID] = getScreenMaxRefreshRate()

            let dimensionToken = started.dimensionToken

            Task { [weak self] in
                if let controller = self?.controllersByStream[streamID] {
                    let reassembler = await controller.getReassembler()
                    reassembler.reset()
                    if let token = dimensionToken { reassembler.updateExpectedDimensionToken(token) }
                }
            }

            if let minW = started.minWidth, let minH = started.minHeight {
                streamMinSizes[streamID] = (minWidth: minW, minHeight: minH)
                MirageLogger.client("Minimum window size: \(minW)x\(minH) pts")
                let minSize = CGSize(width: minW, height: minH)
                sessionStore.updateMinimumSize(for: streamID, minSize: minSize)
                onStreamMinimumSizeUpdate?(streamID, minSize)
            }

            let isAppCentricStream = streamStartedContinuation == nil
            streamStartedContinuation?.resume(returning: streamID)
            streamStartedContinuation = nil

            if !registeredStreamIDs.contains(streamID) {
                registeredStreamIDs.insert(streamID)
                Task {
                    do {
                        await self.setupControllerForStream(streamID)
                        self.addActiveStreamID(streamID)
                        if isAppCentricStream { MirageLogger.client("Controller set up for app-centric stream \(streamID)") }

                        if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                            let reassembler = await controller.getReassembler()
                            reassembler.updateExpectedDimensionToken(token)
                        }

                        if self.udpConnection == nil { try await self.startVideoConnection() }

                        try await self.sendStreamRegistration(streamID: streamID)
                        await self.ensureAudioTransportRegistered(for: streamID)
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                    }
                }
            }
        }
    }

    func handleStreamStopped(_ message: ControlMessage) {
        if let stopped = try? message.decode(StreamStoppedMessage.self) {
            let streamID = stopped.streamID
            activeStreams.removeAll { $0.id == streamID }
            MirageFrameCache.shared.clear(for: streamID)
            metricsStore.clear(streamID: streamID)
            cursorStore.clear(streamID: streamID)
            cursorPositionStore.clear(streamID: streamID)

            removeActiveStreamID(streamID)
            registeredStreamIDs.remove(streamID)
            clearStreamRefreshRateOverride(streamID: streamID)
            clearAdaptiveFallbackState(for: streamID)

            Task { [weak self] in
                guard let self else { return }
                if let controller = controllersByStream[streamID] {
                    await controller.stop()
                    controllersByStream.removeValue(forKey: streamID)
                }
                await updateReassemblerSnapshot()
            }
        }
    }

    func handleStreamMetricsUpdate(_ message: ControlMessage) {
        if let metrics = try? message.decode(StreamMetricsMessage.self) {
            if let controller = controllersByStream[metrics.streamID] {
                Task {
                    await controller.updateDecodeSubmissionLimit(targetFrameRate: metrics.targetFrameRate)
                }
            }
            metricsStore.updateHostMetrics(
                streamID: metrics.streamID,
                encodedFPS: metrics.encodedFPS,
                idleEncodedFPS: metrics.idleEncodedFPS,
                droppedFrames: metrics.droppedFrames,
                activeQuality: Double(metrics.activeQuality),
                targetFrameRate: metrics.targetFrameRate
            )
            updateAdaptiveFallbackPressure(
                streamID: metrics.streamID,
                targetFrameRate: metrics.targetFrameRate
            )
            updateAdaptiveFallbackRecovery(
                streamID: metrics.streamID,
                targetFrameRate: metrics.targetFrameRate
            )

            if let requested = refreshRateOverridesByStream[metrics.streamID] {
                if requested != metrics.targetFrameRate {
                    let updatedCount = (refreshRateMismatchCounts[metrics.streamID] ?? 0) + 1
                    refreshRateMismatchCounts[metrics.streamID] = updatedCount
                    if updatedCount == 2 {
                        MirageLogger.client(
                            "Refresh override pending for stream \(metrics.streamID): requested \(requested)Hz, host \(metrics.targetFrameRate)Hz"
                        )
                    }
                    let fallbackThreshold = 4
                    if updatedCount >= fallbackThreshold {
                        let lastFallback = refreshRateFallbackTargets[metrics.streamID]
                        if lastFallback != requested {
                            refreshRateFallbackTargets[metrics.streamID] = requested
                            Task { [weak self] in
                                try? await self?.sendStreamRefreshRateChange(
                                    streamID: metrics.streamID,
                                    maxRefreshRate: requested,
                                    forceDisplayRefresh: true
                                )
                            }
                            MirageLogger.client(
                                "Refresh override fallback requested for stream \(metrics.streamID): \(requested)Hz"
                            )
                        }
                    }

                    let forcedDowngradeThreshold = 8
                    if requested == 120,
                       metrics.targetFrameRate == 60,
                       updatedCount >= forcedDowngradeThreshold {
                        refreshRateOverridesByStream[metrics.streamID] = 60
                        refreshRateMismatchCounts.removeValue(forKey: metrics.streamID)
                        refreshRateFallbackTargets.removeValue(forKey: metrics.streamID)
                        Task { [weak self] in
                            try? await self?.sendStreamRefreshRateChange(
                                streamID: metrics.streamID,
                                maxRefreshRate: 60
                            )
                        }
                        MirageLogger.client(
                            "Refresh override downgraded to 60Hz for stream \(metrics.streamID) after sustained 120Hz mismatch"
                        )
                    }
                } else {
                    refreshRateMismatchCounts.removeValue(forKey: metrics.streamID)
                    refreshRateFallbackTargets.removeValue(forKey: metrics.streamID)
                }
            }
        }
    }

    func handleErrorMessage(_ message: ControlMessage) {
        if let error = try? message.decode(ErrorMessage.self) { delegate?.clientService(self, didEncounterError: MirageError.protocolError(error.message)) }
    }

    func handleDisconnectMessage(_ message: ControlMessage) async {
        if let disconnect = try? message.decode(DisconnectMessage.self) {
            await handleDisconnect(
                reason: disconnect.reason.rawValue,
                state: .disconnected,
                notifyDelegate: true
            )
        }
    }

    func handleCursorUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(CursorUpdateMessage.self) {
            MirageLogger.client("Cursor update received: \(update.cursorType) (visible: \(update.isVisible))")
            let didChange = cursorStore.updateCursor(
                streamID: update.streamID,
                cursorType: update.cursorType,
                isVisible: update.isVisible
            )
            if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
            onCursorUpdate?(update.streamID, update.cursorType, update.isVisible)
        }
    }

    func handleCursorPositionUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(CursorPositionUpdateMessage.self) {
            let position = CGPoint(x: CGFloat(update.normalizedX), y: CGFloat(update.normalizedY))
            let didChange = cursorPositionStore.updatePosition(
                streamID: update.streamID,
                position: position,
                isVisible: update.isVisible
            )
            if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
        }
    }

    func handleContentBoundsUpdate(_ message: ControlMessage) {
        if let update = try? message.decode(ContentBoundsUpdateMessage.self) {
            MirageLogger.client("Content bounds update for stream \(update.streamID): \(update.bounds)")
            onContentBoundsUpdate?(update.streamID, update.bounds)
            delegate?.clientService(self, didReceiveContentBoundsUpdate: update.bounds, forStream: update.streamID)
        }
    }

    func handleSessionStateUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(SessionStateUpdateMessage.self)
            MirageLogger.client("Host session state: \(update.state), requires username: \(update.requiresUsername)")
            hostSessionState = update.state
            currentSessionToken = update.sessionToken
            delegate?.clientService(
                self,
                hostSessionStateChanged: update.state,
                requiresUsername: update.requiresUsername
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode session state update: \(error)")
        }
    }

    func handleUnlockResponse(_ message: ControlMessage) {
        do {
            let response = try message.decode(UnlockResponseMessage.self)
            MirageLogger.client("Unlock response: success=\(response.success)")
            if response.success {
                hostSessionState = response.newState
                if let token = response.newSessionToken { currentSessionToken = token }
            }
            delegate?.clientService(
                self,
                unlockDidComplete: response.success,
                error: response.error?.message,
                canRetry: response.canRetry,
                retriesRemaining: response.retriesRemaining,
                retryAfterSeconds: response.retryAfterSeconds
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode unlock response: \(error)")
        }
    }

    func handleLoginDisplayReady(_ message: ControlMessage) {
        do {
            let ready = try message.decode(LoginDisplayReadyMessage.self)
            MirageLogger.client("Login display ready: stream=\(ready.streamID), \(ready.width)x\(ready.height)")
            let streamID = StreamID(ready.streamID)
            loginDisplayStreamID = streamID
            loginDisplayResolution = CGSize(width: ready.width, height: ready.height)
            sessionStore.startLoginDisplay(
                streamID: streamID,
                resolution: CGSize(width: ready.width, height: ready.height)
            )

            let dimensionToken = ready.dimensionToken

            Task {
                await self.setupControllerForStream(streamID)
                self.addActiveStreamID(streamID)

                if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                    let reassembler = await controller.getReassembler()
                    reassembler.updateExpectedDimensionToken(token)
                }

                if !self.registeredStreamIDs.contains(streamID) {
                    self.registeredStreamIDs.insert(streamID)
                    do {
                        if self.udpConnection == nil { try await self.startVideoConnection() }
                        try await self.sendStreamRegistration(streamID: streamID)
                        await self.ensureAudioTransportRegistered(for: streamID)
                        MirageLogger.client("Registered for login display video stream \(streamID)")
                    } catch {
                        MirageLogger.error(.client, "Failed to establish video connection for login display: \(error)")
                        self.registeredStreamIDs.remove(streamID)
                    }
                }
            }

            delegate?.clientService(
                self,
                loginDisplayDidStart: StreamID(ready.streamID),
                resolution: CGSize(width: ready.width, height: ready.height),
                sessionState: ready.sessionState,
                requiresUsername: ready.requiresUsername
            )
        } catch {
            MirageLogger.error(.client, "Failed to decode login display ready: \(error)")
        }
    }

    func handleLoginDisplayStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(LoginDisplayStoppedMessage.self)
            let streamID = StreamID(stopped.streamID)
            let borrowedDesktopStream = desktopStreamID != nil && streamID == desktopStreamID
            MirageLogger.client("Login display stopped: stream=\(streamID)")
            loginDisplayStreamID = nil
            loginDisplayResolution = nil
            sessionStore.stopLoginDisplay()
            if borrowedDesktopStream {
                MirageLogger
                    .client("Login display stop shares the active desktop stream; desktop stream state remains active")
            } else {
                metricsStore.clear(streamID: streamID)
                cursorStore.clear(streamID: streamID)
                clearAdaptiveFallbackState(for: streamID)

                removeActiveStreamID(streamID)
                registeredStreamIDs.remove(streamID)

                Task {
                    if let controller = self.controllersByStream[streamID] {
                        await controller.stop()
                        self.controllersByStream.removeValue(forKey: streamID)
                    }
                    await self.updateReassemblerSnapshot()
                }
            }

            delegate?.clientService(self, loginDisplayDidStop: streamID, newState: stopped.newState)
        } catch {
            MirageLogger.error(.client, "Failed to decode login display stopped: \(error)")
        }
    }
}
