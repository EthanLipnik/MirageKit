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
import Network

@MainActor
extension MirageClientService {
    func finalizeAcceptedBootstrap(
        _ response: MirageSessionBootstrapResponse,
        hostIdentityKeyID: String
    ) async -> LoomPeer {
        connectedHostIdentityKeyID = hostIdentityKeyID
        hasCompletedBootstrap = true
        isAwaitingManualApproval = false

        let acceptedHost = await canonicalConnectedHost(
            hostID: response.hostID,
            hostName: response.hostName,
            hostIdentityKeyID: hostIdentityKeyID
        )
        connectedHost = acceptedHost
        connectionState = .connected(host: acceptedHost.name)
        return acceptedHost
    }

    func canonicalConnectedHost(
        hostID: UUID,
        hostName: String,
        hostIdentityKeyID: String
    ) async -> LoomPeer {
        let provisionalHost = connectedHost
        let resolvedHostName = hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? provisionalHost?.name ?? "Host" : hostName
        let controlRemoteEndpoint = await currentControlRemoteEndpoint()
        let hostEndpoint: NWEndpoint = provisionalHost?.endpoint
            ?? controlRemoteEndpoint
            ?? .service(
                name: resolvedHostName,
                type: MirageKit.serviceType,
                domain: "",
                interface: nil
            )
        let deviceType = provisionalHost?.deviceType
            ?? provisionalHost?.advertisement.deviceType
            ?? .unknown
        let sourceAdvertisement = provisionalHost?.advertisement ?? LoomPeerAdvertisement()
        let canonicalAdvertisement = LoomPeerAdvertisement(
            protocolVersion: sourceAdvertisement.protocolVersion,
            deviceID: hostID,
            identityKeyID: hostIdentityKeyID,
            deviceType: sourceAdvertisement.deviceType ?? deviceType,
            modelIdentifier: sourceAdvertisement.modelIdentifier,
            iconName: sourceAdvertisement.iconName,
            machineFamily: sourceAdvertisement.machineFamily,
            metadata: sourceAdvertisement.metadata
        )

        if let provisionalHost, provisionalHost.deviceID != hostID {
            MirageLogger.client(
                "Canonicalizing connected host identity provisional=\(provisionalHost.deviceID.uuidString) accepted=\(hostID.uuidString)"
            )
        }

        return LoomPeer(
            id: hostID,
            name: resolvedHostName,
            deviceType: deviceType,
            endpoint: hostEndpoint,
            advertisement: canonicalAdvertisement
        )
    }

    nonisolated static func shouldAcceptSessionMediaEncryption(
        mediaEncryptionEnabled: Bool,
        requireEncryptedMediaOnLocalNetwork: Bool
    ) -> Bool {
        mediaEncryptionEnabled || !requireEncryptedMediaOnLocalNetwork
    }

    func protocolMismatchInfo(from response: MirageSessionBootstrapResponse) -> ProtocolMismatchInfo? {
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

    func mapProtocolMismatchReason(_ reason: MirageSessionBootstrapRejectionReason?) -> ProtocolMismatchInfo.Reason {
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

    func bootstrapRejectionDescription(
        for response: MirageSessionBootstrapResponse,
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

    func handleBootstrapResponse(
        _ response: MirageSessionBootstrapResponse,
        provisionalHost: LoomPeer,
        session: LoomAuthenticatedSession
    ) async throws {
        guard let context = await session.context else {
            throw MirageError.protocolError("Loom session missing authenticated context")
        }

        let peerIdentity = context.peerIdentity
        guard let hostIdentityKeyID = peerIdentity.identityKeyID else {
            throw MirageError.protocolError("Authenticated Loom session is missing host identity key")
        }
        if let expectedHostIdentityKeyID, expectedHostIdentityKeyID != hostIdentityKeyID {
            throw MirageError.protocolError("Host identity mismatch")
        }

        if response.accepted {
            guard Self.shouldAcceptSessionMediaEncryption(
                mediaEncryptionEnabled: response.mediaEncryptionEnabled,
                requireEncryptedMediaOnLocalNetwork: networkConfig.requireEncryptedMediaOnLocalNetwork
            ) else {
                throw MirageError.protocolError("Host media encryption disabled (client policy blocks unencrypted media)")
            }
            guard response.udpRegistrationToken.count == MirageMediaSecurity.registrationTokenLength else {
                throw MirageError.protocolError("Invalid UDP registration token")
            }

            let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
            let localIdentity = try resolvedIdentityManager.currentIdentity()
            let mediaContext = try MirageMediaSecurity.deriveContextForAuthenticatedSession(
                identityManager: resolvedIdentityManager,
                peerPublicKey: peerIdentity.identityPublicKey ?? Data(),
                hostID: response.hostID,
                clientID: deviceID,
                hostKeyID: hostIdentityKeyID,
                clientKeyID: localIdentity.keyID,
                udpRegistrationToken: response.udpRegistrationToken
            )

            let requiredFeatures: MirageFeatureSet = [
                .udpRegistrationAuthV1,
                .encryptedMediaV1,
            ]
            guard response.selectedFeatures.contains(requiredFeatures) else {
                throw MirageError.protocolError("Protocol features mismatch")
            }

            setMediaSecurityContext(mediaContext)
            mediaPayloadEncryptionEnabled = response.mediaEncryptionEnabled
            negotiatedFeatures = response.selectedFeatures
            connectedHostAllowsRemoteAccess = response.remoteAccessAllowed
            let acceptedHost = await finalizeAcceptedBootstrap(
                response,
                hostIdentityKeyID: hostIdentityKeyID
            )

            if response.autoTrustGranted == true {
                let hostComponent = response.hostID.uuidString.lowercased()
                let noticeKey = "com.mirage.autotrust.client.\(hostComponent)"
                if !UserDefaults.standard.bool(forKey: noticeKey) {
                    UserDefaults.standard.set(true, forKey: noticeKey)
                    let hostDisplayName = response.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if hostDisplayName.isEmpty {
                        onAutoTrustNotice?("Auto-approved trusted device for this host.")
                    } else {
                        onAutoTrustNotice?("Auto-approved trusted device for \(hostDisplayName).")
                    }
                }
            }

            MirageLogger.client("Mirage bootstrap accepted by \(acceptedHost.name)")
            MirageInstrumentation.record(.clientHelloAccepted)
            if connectedHost == nil {
                connectedHost = provisionalHost
            }
        } else {
            let mismatchInfo = protocolMismatchInfo(from: response)
            if let mismatchInfo {
                onProtocolMismatch?(mismatchInfo)
            }
            let rejectionDescription = bootstrapRejectionDescription(for: response, mismatchInfo: mismatchInfo)
            MirageLogger.client("Connection rejected by host: \(rejectionDescription)")
            MirageInstrumentation.record(.clientHelloRejected(helloRejectionReason(response.rejectionReason)))
            throw MirageError.protocolError(rejectionDescription)
        }
    }

    func handleWindowList(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsWindowListRefresh = true
            return
        }
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
            MirageLogger.error(.client, error: error, message: "Failed to decode window list: ")
        }
    }

    func handleWindowUpdate(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsWindowListRefresh = true
            return
        }
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

    func handleStreamStarted(_ message: ControlMessage) async {
        if let started = try? message.decode(StreamStartedMessage.self) {
            let streamID = started.streamID
            let startupAttemptID = started.startupAttemptID
            guard shouldAcceptStartupAttempt(startupAttemptID, for: streamID) else {
                MirageLogger.client(
                    "Ignoring stale streamStarted for stream \(streamID) startupAttemptID=\(startupAttemptID?.uuidString ?? "nil")"
                )
                return
            }
            MirageLogger.client("Stream started: \(streamID) for window \(started.windowID)")
            let resolvedWindow = resolveWindowForStartedStream(
                streamID: streamID,
                started: started
            )
            upsertActiveStreamSession(
                streamID: streamID,
                window: resolvedWindow
            )

            let screenMaxRefreshRate = getScreenMaxRefreshRate()
            let existingRefreshRate = refreshRateOverridesByStream[streamID] ?? 0
            let desiredRefreshRate = max(existingRefreshRate, screenMaxRefreshRate)
            refreshRateOverridesByStream[streamID] = desiredRefreshRate >= 120 ? 120 : 60

            let dimensionToken = started.dimensionToken
            let hasController = controllersByStream[streamID] != nil
            let isExistingStream = activeStreams.contains(where: { $0.id == streamID }) ||
                sessionStore.sessionByStreamID(streamID) != nil
            let previousDimensionToken = appDimensionTokenByStream[streamID]
            let resetDecision = appStreamStartResetDecision(
                streamID: streamID,
                isExistingStream: isExistingStream,
                hasController: hasController,
                requestStartPending: streamStartedContinuation != nil,
                previousDimensionToken: previousDimensionToken,
                receivedDimensionToken: dimensionToken
            )
            let shouldResetController = resetDecision == .resetController
            let shouldSetupController = shouldResetController || !hasController
            let wasRegistered = registeredStreamIDs.contains(streamID)
            let registrationDecision = appStreamRegistrationRefreshDecision(
                hasController: hasController,
                shouldResetController: shouldResetController,
                wasRegistered: wasRegistered
            )
            let shouldRegisterVideo = registrationDecision == .refreshRegistration
            if let previousDimensionToken, let dimensionToken, previousDimensionToken != dimensionToken {
                MirageLogger
                    .client(
                        "App stream token advanced \(previousDimensionToken) -> \(dimensionToken); reset=\(shouldResetController)"
                    )
            }
            if let dimensionToken {
                appDimensionTokenByStream[streamID] = dimensionToken
            }
            appStreamStartAcknowledgementByStreamID[streamID] = StreamStartAcknowledgement(
                width: started.width,
                height: started.height,
                dimensionToken: dimensionToken
            )

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
            let shouldMarkStartupPending = isAppCentricStream && shouldRegisterVideo

            if shouldMarkStartupPending {
                streamStartupBaseTimes[streamID] = CFAbsoluteTimeGetCurrent()
                streamStartupFirstRegistrationSent.remove(streamID)
                streamStartupFirstPacketReceived.remove(streamID)
                markStartupPacketPending(streamID)
            }
            registerStartupAttempt(startupAttemptID, for: streamID)

            if shouldSetupController {
                await self.setupControllerForStream(
                    streamID,
                    mediaMaxPacketSize: started.acceptedMediaMaxPacketSize
                )
            }
            self.addActiveStreamID(streamID)
            if isAppCentricStream, shouldSetupController {
                MirageLogger.client("Controller set up for app-centric stream \(streamID)")
            }

            if let token = dimensionToken, let controller = self.controllersByStream[streamID] {
                let reassembler = await controller.getReassembler()
                reassembler.updateExpectedDimensionToken(token)
            }

            if let startupAttemptID {
                await self.sendStreamReadyAck(
                    streamID: streamID,
                    startupAttemptID: startupAttemptID,
                    kind: .window
                )
            }

            if shouldRegisterVideo {
                self.registeredStreamIDs.insert(streamID)
                let refreshRate = self.refreshRateOverridesByStream[streamID] ?? self.getScreenMaxRefreshRate()
                try? await self.sendStreamRefreshRateChange(
                    streamID: streamID,
                    maxRefreshRate: refreshRate
                )
                MirageLogger.client(
                    "Refresh override sync sent for stream \(streamID): \(refreshRate)Hz"
                )
                if shouldMarkStartupPending {
                    self.startStartupRegistrationRetry(streamID: streamID)
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
            inputEventSender.clearTemporaryPointerCoalescing(for: streamID)
            clearDecoderColorDepthState(for: streamID)
            mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
            clearStartupAttempt(for: streamID)
            appDimensionTokenByStream.removeValue(forKey: streamID)
            appStreamStartAcknowledgementByStreamID.removeValue(forKey: streamID)
            streamStartupBaseTimes.removeValue(forKey: streamID)
            streamStartupFirstRegistrationSent.remove(streamID)
            streamStartupFirstPacketReceived.remove(streamID)
            clearStartupPacketPending(streamID)
            cancelStartupRegistrationRetry(streamID: streamID)
            cancelRecoveryKeyframeRetry(for: streamID)
            activeJitterHoldMs = 0

            Task { [weak self] in
                guard let self else { return }
                if let controller = controllersByStream[streamID] {
                    await controller.stop()
                    controllersByStream.removeValue(forKey: streamID)
                    heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
                }
                await updateReassemblerSnapshot()
            }

            refreshSharedClipboardBridgeState()
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
                targetFrameRate: metrics.targetFrameRate,
                enteredBitrate: metrics.enteredBitrate,
                currentBitrate: metrics.currentBitrate,
                requestedTargetBitrate: metrics.requestedTargetBitrate,
                bitrateAdaptationCeiling: metrics.bitrateAdaptationCeiling,
                startupBitrate: metrics.startupBitrate,
                temporaryDegradationMode: metrics.temporaryDegradationMode,
                temporaryDegradationColorDepth: metrics.temporaryDegradationColorDepth,
                timeBelowTargetBitrateMs: metrics.timeBelowTargetBitrateMs,
                captureAdmissionDrops: metrics.captureAdmissionDrops,
                frameBudgetMs: metrics.frameBudgetMs,
                averageEncodeMs: metrics.averageEncodeMs,
                captureIngressFPS: metrics.captureIngressFPS,
                captureFPS: metrics.captureFPS,
                encodeAttemptFPS: metrics.encodeAttemptFPS,
                usingHardwareEncoder: metrics.usingHardwareEncoder,
                encoderGPURegistryID: metrics.encoderGPURegistryID,
                encodedWidth: metrics.encodedWidth,
                encodedHeight: metrics.encodedHeight,
                capturePixelFormat: metrics.capturePixelFormat,
                captureColorPrimaries: metrics.captureColorPrimaries,
                encoderPixelFormat: metrics.encoderPixelFormat,
                encoderChromaSampling: metrics.encoderChromaSampling,
                encoderProfile: metrics.encoderProfile,
                encoderColorPrimaries: metrics.encoderColorPrimaries,
                encoderTransferFunction: metrics.encoderTransferFunction,
                encoderYCbCrMatrix: metrics.encoderYCbCrMatrix,
                displayP3CoverageStatus: metrics.displayP3CoverageStatus,
                tenBitDisplayP3Validated: metrics.tenBitDisplayP3Validated,
                ultra444Validated: metrics.ultra444Validated
            )
            metricsStore.updateHostPipelineMetrics(
                streamID: metrics.streamID,
                captureIngressAverageMs: metrics.captureIngressAverageMs,
                captureIngressMaxMs: metrics.captureIngressMaxMs,
                preEncodeWaitAverageMs: metrics.preEncodeWaitAverageMs,
                preEncodeWaitMaxMs: metrics.preEncodeWaitMaxMs,
                captureCallbackAverageMs: metrics.captureCallbackAverageMs,
                captureCallbackMaxMs: metrics.captureCallbackMaxMs,
                captureCopyAverageMs: metrics.captureCopyAverageMs,
                captureCopyMaxMs: metrics.captureCopyMaxMs,
                captureCopyPoolDrops: metrics.captureCopyPoolDrops,
                captureCopyInFlightDrops: metrics.captureCopyInFlightDrops,
                sendQueueBytes: metrics.sendQueueBytes,
                sendStartDelayAverageMs: metrics.sendStartDelayAverageMs,
                sendStartDelayMaxMs: metrics.sendStartDelayMaxMs,
                sendCompletionAverageMs: metrics.sendCompletionAverageMs,
                sendCompletionMaxMs: metrics.sendCompletionMaxMs,
                packetPacerAverageSleepMs: metrics.packetPacerAverageSleepMs,
                packetPacerMaxSleepMs: metrics.packetPacerMaxSleepMs,
                stalePacketDrops: metrics.stalePacketDrops,
                generationAbortDrops: metrics.generationAbortDrops,
                nonKeyframeHoldDrops: metrics.nonKeyframeHoldDrops
            )
            if let requested = refreshRateOverridesByStream[metrics.streamID] {
                guard metrics.streamID == desktopStreamID else {
                    refreshRateMismatchCounts.removeValue(forKey: metrics.streamID)
                    refreshRateFallbackTargets.removeValue(forKey: metrics.streamID)
                    return
                }
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

    func handleTransportRefreshRequest(_ message: ControlMessage) {
        guard awdlExperimentEnabled else { return }
        do {
            let request = try message.decode(TransportRefreshRequestMessage.self)
            transportRefreshRequests &+= 1
            MirageLogger.client(
                "Host transport refresh request received: reason=\(request.reason), stream=\(request.streamID.map(String.init) ?? "all"), count=\(transportRefreshRequests)"
            )
            let activeIDs = activeStreamIDsForFiltering
            let targetIDs: [StreamID] = if let filterID = request.streamID {
                activeIDs.contains(filterID) ? [filterID] : []
            } else {
                activeIDs.sorted()
            }
            for streamID in targetIDs {
                sendKeyframeRequest(for: streamID)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode transport refresh request: ")
        }
    }

    func handleErrorMessage(_ message: ControlMessage) {
        if let errorMessage = try? message.decode(ErrorMessage.self) {
            let disposition = desktopStreamStartFailureDisposition(
                errorCode: errorMessage.code,
                desktopStartPending: desktopStreamMode != nil || desktopStreamRequestStartTime > 0,
                hasActiveDesktopStream: desktopStreamID != nil
            )
            if disposition == .clearPendingStart {
                clearPendingDesktopStreamStartState()
            }
            if let runtimeCondition = errorMessage.code.runtimeConditionError {
                delegate?.clientService(self, didEncounterError: runtimeCondition)
            } else {
                delegate?.clientService(self, didEncounterError: MirageError.protocolError(errorMessage.message))
            }
        }
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
            recordCursorControlReceiveSample(updateReceived: true, positionReceived: false)
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
            recordCursorControlReceiveSample(updateReceived: false, positionReceived: true)
            let position = CGPoint(x: CGFloat(update.normalizedX), y: CGFloat(update.normalizedY))
            let didChange = cursorPositionStore.updatePosition(
                streamID: update.streamID,
                position: position,
                isVisible: update.isVisible
            )
            if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
        }
    }

    private func recordCursorControlReceiveSample(updateReceived: Bool, positionReceived: Bool) {
        if updateReceived { cursorUpdateMessagesSinceLastSample &+= 1 }
        if positionReceived { cursorPositionMessagesSinceLastSample &+= 1 }

        let now = CFAbsoluteTimeGetCurrent()
        if lastCursorControlSampleTime == 0 {
            lastCursorControlSampleTime = now
            return
        }
        guard now - lastCursorControlSampleTime >= cursorControlSampleInterval else { return }

        let updateCount = cursorUpdateMessagesSinceLastSample
        let positionCount = cursorPositionMessagesSinceLastSample
        cursorUpdateMessagesSinceLastSample = 0
        cursorPositionMessagesSinceLastSample = 0
        lastCursorControlSampleTime = now
        guard updateCount > 0 || positionCount > 0 else { return }

        MirageLogger.client(
            "Cursor control sample (1s): cursorUpdates=\(updateCount), cursorPositions=\(positionCount)"
        )
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
            MirageLogger.client("Host session state: \(update.state), requires username: \(update.requiresUserIdentifier)")
            hostSessionState = update.state
            currentSessionToken = update.sessionToken
            delegate?.clientService(
                self,
                hostSessionStateChanged: update.state,
                requiresUserIdentifier: update.requiresUserIdentifier
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode session state update: ")
        }
    }

    private func recordHelloValidationFailure(_ reason: MirageClientHelloValidationStepReason) {
        MirageInstrumentation.record(.clientHelloInvalid(reason))
    }

    private func resolveWindowForStartedStream(
        streamID: StreamID,
        started: StreamStartedMessage
    ) -> MirageWindow {
        let fallbackFrame = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, started.width)),
            height: CGFloat(max(1, started.height))
        )
        let windowTemplate = activeStreams.first(where: { $0.id == streamID })?.window ??
            sessionStore.sessionByStreamID(streamID)?.window ??
            availableWindows.first(where: { $0.id == started.windowID })

        guard let template = windowTemplate else {
            return MirageWindow(
                id: started.windowID,
                title: nil,
                application: nil,
                frame: fallbackFrame,
                isOnScreen: true,
                windowLayer: 0
            )
        }

        let templateFrame = template.frame
        let mergedFrame = CGRect(
            x: templateFrame.origin.x,
            y: templateFrame.origin.y,
            width: CGFloat(max(1, started.width)),
            height: CGFloat(max(1, started.height))
        )

        return MirageWindow(
            id: started.windowID,
            title: template.title,
            application: template.application,
            frame: mergedFrame,
            isOnScreen: template.isOnScreen,
            windowLayer: template.windowLayer
        )
    }

    func upsertActiveStreamSession(
        streamID: StreamID,
        window: MirageWindow
    ) {
        let session = ClientStreamSession(id: streamID, window: window)
        if let index = activeStreams.firstIndex(where: { $0.id == streamID }) {
            activeStreams[index] = session
        } else {
            activeStreams.append(session)
        }
        refreshSharedClipboardBridgeState()
    }

    private func helloRejectionReason(_ reason: MirageSessionBootstrapRejectionReason?) -> MirageHelloRejectionStepReason {
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
}
