//
//  MirageClientService+WindowStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Per-window stream lifecycle and controller setup.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Start viewing a remote window.
    /// - Parameters:
    ///   - window: The remote window to stream.
    ///   - expectedPixelSize: Optional pixel dimensions the client expects to render at.
    ///     If provided, the host will encode at this resolution from the start.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///     Used with expectedPixelSize to calculate point-based window size.
    ///   - displayResolution: Client's logical display size in points.
    ///     Host applies HiDPI (2x) to determine virtual display pixel resolution.
    ///   - keyFrameInterval: Optional keyframe interval in frames. Higher = fewer lag spikes.
    ///     Examples: 600 (10 seconds @ 60fps), 300 (5 seconds @ 60fps).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    func startViewing(
        window: MirageWindow,
        expectedPixelSize: CGSize? = nil,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil
    )
    async throws -> ClientStreamSession {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        await cancelActiveQualityTest(
            reason: "interactive app stream startup",
            notifyHost: true
        )

        // Note: Decoder/reassembler are created per-stream AFTER receiving streamStarted with the stream ID.
        var request = StartStreamMessage(
            windowID: window.id,
            dataPort: nil,
            targetFrameRate: getScreenMaxRefreshRate()
        )
        request.mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize()
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for window streaming")
        }
        if let expectedPixelSize, expectedPixelSize.width > 0, expectedPixelSize.height > 0 {
            request.pixelWidth = Int(expectedPixelSize.width)
            request.pixelHeight = Int(expectedPixelSize.height)
        }

        // Include display resolution for virtual display sizing.
        if effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 {
            request.displayWidth = Int(effectiveDisplayResolution.width)
            request.displayHeight = Int(effectiveDisplayResolution.height)
            MirageLogger
                .client(
                    "Including display size: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height)) pts"
                )
        }

        // Include encoder config overrides if specified.
        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &request)
        if let colorDepth = request.colorDepth {
            pendingRequestedColorDepthByWindowID[window.id] = colorDepth
        } else {
            pendingRequestedColorDepthByWindowID.removeValue(forKey: window.id)
        }

        request.audioConfiguration = audioConfiguration ?? self.audioConfiguration
        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor,
            requestedStreamScale: clampedStreamScale(),
            encoderMaxWidth: request.encoderMaxWidth,
            encoderMaxHeight: request.encoderMaxHeight,
            disableResolutionCap: request.disableResolutionCap == true
        )
        resolutionScale = geometry.resolvedStreamScale
        request.scaleFactor = geometry.displayScaleFactor
        request.streamScale = geometry.resolvedStreamScale

        MirageLogger.client(
            "Sending startStream for window \(window.id): " +
                "\(Int(geometry.logicalSize.width))x\(Int(geometry.logicalSize.height)) pts, " +
                "\(Int(geometry.displayPixelSize.width))x\(Int(geometry.displayPixelSize.height)) px, " +
                "encode \(Int(geometry.encodedPixelSize.width))x\(Int(geometry.encodedPixelSize.height)) px"
        )
        try await sendControlMessage(.startStream, content: request)

        // Wait for streamStarted response from server to get the real stream ID.
        let realStreamID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            StreamID,
            Error
        >) in
            self.streamStartedContinuation = continuation
        }
        let pendingColorDepth = pendingRequestedColorDepthByWindowID.removeValue(forKey: window.id)
        configureDecoderColorDepthBaseline(for: realStreamID, colorDepth: pendingColorDepth)

        MirageLogger.client("Stream started with ID \(realStreamID)")

        let session = ClientStreamSession(
            id: realStreamID,
            window: window
        )

        upsertActiveStreamSession(streamID: realStreamID, window: window)
        return session
    }

    /// Set up or reset controller for a specific stream.
    /// StreamController owns the decoder, reassembler, and resize state machine.
    internal func setupControllerForStream(
        _ streamID: StreamID,
        beginPostResizeTransition: Bool = false,
        codec: MirageVideoCodec = .hevc,
        streamDimensions: (width: Int, height: Int)? = nil,
        mediaMaxPacketSize: Int? = nil,
        dimensionToken: UInt16? = nil,
        forwardsResizeEvents: Bool = true,
        resizeEventStreamID: StreamID? = nil,
        targetFrameRate: Int? = nil
    )
    async {
        let resolvedResizeEventStreamID = forwardsResizeEvents ? (resizeEventStreamID ?? streamID) : nil
        let preferredDecoderColorDepth = resolvedDecoderColorDepth(for: streamID)
        let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(mediaMaxPacketSize)
        let payloadSize = miragePayloadSize(maxPacketSize: acceptedMediaMaxPacketSize)
        let resolvedTargetFrameRate = resolvedStreamCadenceFrameRate(
            for: streamID,
            fallback: targetFrameRate
        )

        if let existingController = controllersByStream[streamID] {
            let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[streamID] ?? mirageDefaultMaxPacketSize
            guard previousMediaMaxPacketSize == acceptedMediaMaxPacketSize else {
                await existingController.stop()
                controllersByStream.removeValue(forKey: streamID)
                mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
                MirageLogger.client(
                    "Recreating controller for stream \(streamID) due to media packet size change \(previousMediaMaxPacketSize)B -> \(acceptedMediaMaxPacketSize)B"
                )
                return await setupControllerForStream(
                    streamID,
                    beginPostResizeTransition: beginPostResizeTransition,
                    codec: codec,
                    streamDimensions: streamDimensions,
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                    dimensionToken: dimensionToken,
                    forwardsResizeEvents: forwardsResizeEvents,
                    resizeEventStreamID: resolvedResizeEventStreamID,
                    targetFrameRate: resolvedTargetFrameRate
                )
            }

            if !beginPostResizeTransition, let dimensionToken {
                let reassembler = await existingController.getReassembler()
                reassembler.updateExpectedDimensionToken(dimensionToken)
            }
            await existingController.setDecoderCodec(codec, streamDimensions: streamDimensions)
            await existingController.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
            await existingController.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
            await existingController.resetForNewSession()
            if beginPostResizeTransition {
                await existingController.primeForIncomingResize(
                    dimensionToken: dimensionToken,
                    streamDimensions: streamDimensions
                )
                await existingController.beginPostResizeTransition()
            }
            let tier = sessionStore.presentationTier(for: streamID)
            await existingController.updateCadenceTarget(
                sourceFPS: resolvedTargetFrameRate,
                displayFPS: resolvedTargetFrameRate,
                latencyMode: renderLatencyModeByStream[streamID],
                reason: "controller reset"
            )
            await existingController.updatePresentationTier(tier, targetFPS: resolvedTargetFrameRate)
            decoderCompatibilityFallbackLastAppliedTime[streamID] = 0
            mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
            MirageLogger
                .client(
                    "Reset existing controller for stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName))"
                )
            replayPendingApplicationActivationRecoveryIfNeeded(for: streamID)
            return
        }

        let controller = StreamController(streamID: streamID, maxPayloadSize: payloadSize)
        controllersByStream[streamID] = controller
        mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
        if decoderCompatibilityBaselineColorDepthByStream[streamID] == nil,
           pendingAppRequestedColorDepth != nil {
            configureDecoderColorDepthBaseline(
                for: streamID,
                colorDepth: pendingAppRequestedColorDepth
            )
        }
        decoderCompatibilityFallbackLastAppliedTime[streamID] = 0

        await controller.setDecoderCodec(codec, streamDimensions: streamDimensions)
        await controller.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
        await controller.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
        if let dimensionToken {
            let reassembler = await controller.getReassembler()
            reassembler.updateExpectedDimensionToken(dimensionToken)
        }

        let capturedStreamID = streamID
        await controller.setCallbacks(
            onKeyframeNeeded: { [weak self] in
                self?.sendKeyframeRequest(for: capturedStreamID)
            },
            onResizeEvent: { [weak self] event in
                guard let resolvedResizeEventStreamID else { return }
                self?.handleResizeEvent(event, for: resolvedResizeEventStreamID)
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self] metrics in
                guard let self else { return }
                metricsStore.updateClientMetrics(
                    streamID: capturedStreamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    receivedWorstGapMs: metrics.receivedWorstGapMs,
                    receivedFrameIntervalP95Ms: metrics.receivedFrameIntervalP95Ms,
                    receivedFrameIntervalP99Ms: metrics.receivedFrameIntervalP99Ms,
                    droppedFrames: metrics.droppedFrames,
                    reassemblerPendingFrameCount: metrics.reassemblerPendingFrameCount,
                    reassemblerPendingKeyframeCount: metrics.reassemblerPendingKeyframeCount,
                    reassemblerPendingBytes: metrics.reassemblerPendingBytes,
                    frameBufferPoolRetainedBytes: metrics.frameBufferPoolRetainedBytes,
                    reassemblerBudgetEvictions: metrics.reassemblerBudgetEvictions,
                    displayTickFPS: metrics.displayTickFPS,
                    submitAttemptFPS: metrics.submitAttemptFPS,
                    layerEnqueueFPS: metrics.layerEnqueueFPS,
                    uniqueLayerEnqueueFPS: metrics.uniqueLayerEnqueueFPS,
                    pendingFrameCount: metrics.pendingFrameCount,
                    unsubmittedPendingFrameCount: metrics.unsubmittedPendingFrameCount,
                    retainedSubmittedFrameCount: metrics.retainedSubmittedFrameCount,
                    pendingFrameAgeMs: metrics.pendingFrameAgeMs,
                    oldestUnsubmittedAgeMs: metrics.oldestUnsubmittedAgeMs,
                    newestUnsubmittedAgeMs: metrics.newestUnsubmittedAgeMs,
                    overwrittenPendingFrames: metrics.overwrittenPendingFrames,
                    lateFrameDrops: metrics.lateFrameDrops,
                    displayLayerNotReadyCount: metrics.displayLayerNotReadyCount,
                    repeatedFrameCount: metrics.repeatedFrameCount,
                    displayTickNoFrameCount: metrics.displayTickNoFrameCount,
                    frameArrivalFallbackCount: metrics.frameArrivalFallbackCount,
                    missedVSyncCount: metrics.missedVSyncCount,
                    displayTickIntervalP95Ms: metrics.displayTickIntervalP95Ms,
                    displayTickIntervalP99Ms: metrics.displayTickIntervalP99Ms,
                    playoutDelayFrames: metrics.playoutDelayFrames,
                    presentationStallCount: metrics.presentationStallCount,
                    worstPresentationGapMs: metrics.worstPresentationGapMs,
                    frameIntervalP95Ms: metrics.frameIntervalP95Ms,
                    frameIntervalP99Ms: metrics.frameIntervalP99Ms,
                    frameIntervalMaxMs: metrics.frameIntervalMaxMs,
                    displayTickIntervalMaxMs: metrics.displayTickIntervalMaxMs,
                    decodeHealthy: metrics.decodeHealthy
                )
                metricsStore.updateClientTimingDiagnostics(
                    streamID: capturedStreamID,
                    coalescedBeforeSubmitCount: metrics.coalescedBeforeSubmitCount,
                    duplicateRemoteTimestampCount: metrics.duplicateRemoteTimestampCount,
                    correctedStreamTimestampCount: metrics.correctedStreamTimestampCount
                )
                metricsStore.updateClientPresentationDiagnostics(
                    streamID: capturedStreamID,
                    renderStoreClearCount: metrics.renderStoreClearCount,
                    renderGenerationBumpCount: metrics.renderGenerationBumpCount,
                    renderMemoryTrimClearCount: metrics.renderMemoryTrimClearCount,
                    presenterTimingResetCount: metrics.presenterTimingResetCount,
                    displayLayerLivenessResetCount: metrics.displayLayerLivenessResetCount,
                    presentationRecoveryRequestCount: metrics.presentationRecoveryRequestCount,
                    presentationRecoveryHandlerDispatchCount: metrics.presentationRecoveryHandlerDispatchCount,
                    lastRenderGenerationBumpReason: metrics.lastRenderGenerationBumpReason,
                    lastPresentationRecoveryOutcome: metrics.lastPresentationRecoveryOutcome
                )
                metricsStore.updateClientDecoderTelemetry(
                    streamID: capturedStreamID,
                    outputPixelFormat: metrics.decoderOutputPixelFormat,
                    usingHardwareDecoder: metrics.usingHardwareDecoder
                )
                if self.activeJitterHoldMs != metrics.activeJitterHoldMs {
                    self.activeJitterHoldMs = metrics.activeJitterHoldMs
                }
                self.logAwdlExperimentTelemetryIfNeeded()
            },
            onMediaFeedback: { [weak self] feedback in
                self?.sendReceiverMediaFeedback(feedback)
            },
            onFirstFrameDecoded: { [weak self] in
                self?.sessionStore.markFirstFrameDecoded(for: capturedStreamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFrameDecoded", "stream=\(capturedStreamID)")
            },
            onPostResizeFrameDecoded: { [weak self] in
                self?.handlePostResizeFrameDecoded(streamID: capturedStreamID)
            },
            onFirstFramePresented: { [weak self] in
                self?.handleStreamFirstFramePresented(streamID: capturedStreamID)
                self?.clearStartupAttempt(for: capturedStreamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFramePresented", "stream=\(capturedStreamID)")
            },
            onStallEvent: { [weak self] event in
                guard let self else { return }
                self.stallEvents &+= 1
                self.inputEventSender.activateTemporaryPointerCoalescing(for: capturedStreamID, duration: 1.2)
                self.handleRuntimeWorkloadSafetyStallEvent(streamID: capturedStreamID, event: event)
                self.logAwdlExperimentTelemetryIfNeeded()
            },
            onRecoveryStatusChanged: { [weak self] status in
                self?.sessionStore.setClientRecoveryStatus(for: capturedStreamID, status: status)
                if status == .idle {
                    self?.handleDesktopPresentationReady(streamID: capturedStreamID)
                }
            },
            onTerminalStartupFailure: { [weak self] failure in
                Task {
                    await self?.handleTerminalStartupFailure(failure, for: capturedStreamID)
                }
            },
            onTerminalLiveRecoveryFailure: { [weak self] failure in
                Task {
                    await self?.handleTerminalLiveRecoveryFailure(failure, for: capturedStreamID)
                }
            }
        )

        await controller.updateCadenceTarget(
            sourceFPS: resolvedTargetFrameRate,
            displayFPS: resolvedTargetFrameRate,
            latencyMode: renderLatencyModeByStream[streamID],
            reason: "controller setup"
        )
        if let kind = controlPathSnapshot?.kind {
            await controller.setTransportPathKind(kind)
        }
        if beginPostResizeTransition {
            await controller.beginPostResizeTransition()
        }
        await controller.start()
        await controller.updatePresentationTier(
            sessionStore.presentationTier(for: streamID),
            targetFPS: resolvedTargetFrameRate
        )
        await updateReassemblerSnapshot()

        MirageLogger
            .client(
                "Created new controller for stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName), media packet \(acceptedMediaMaxPacketSize)B)"
            )
        replayPendingApplicationActivationRecoveryIfNeeded(for: streamID)
    }

    internal func prepareControllerForDesktopResize(
        _ streamID: StreamID,
        codec: MirageVideoCodec,
        streamDimensions: (width: Int, height: Int)?,
        mediaMaxPacketSize: Int?,
        dimensionToken: UInt16?,
        targetFrameRate: Int? = nil
    )
    async {
        let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(mediaMaxPacketSize)
        let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[streamID] ?? mirageDefaultMaxPacketSize
        let resolvedTargetFrameRate = resolvedStreamCadenceFrameRate(
            for: streamID,
            fallback: targetFrameRate
        )
        guard previousMediaMaxPacketSize == acceptedMediaMaxPacketSize else {
            if let existingController = controllersByStream[streamID] {
                await existingController.stop()
                controllersByStream.removeValue(forKey: streamID)
                mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
            }
            MirageLogger.client(
                "Recreating controller for desktop resize on stream \(streamID) due to media packet size change \(previousMediaMaxPacketSize)B -> \(acceptedMediaMaxPacketSize)B"
            )
            return await setupControllerForStream(
                streamID,
                beginPostResizeTransition: true,
                codec: codec,
                streamDimensions: streamDimensions,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                dimensionToken: dimensionToken,
                targetFrameRate: resolvedTargetFrameRate
            )
        }

        guard let existingController = controllersByStream[streamID] else {
            return await setupControllerForStream(
                streamID,
                beginPostResizeTransition: true,
                codec: codec,
                streamDimensions: streamDimensions,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                dimensionToken: dimensionToken,
                targetFrameRate: resolvedTargetFrameRate
            )
        }

        let preferredDecoderColorDepth = resolvedDecoderColorDepth(for: streamID)
        await existingController.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
        await existingController.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
        await existingController.prepareForResize(
            codec: codec,
            streamDimensions: streamDimensions
        )
        await existingController.primeForIncomingResize(
            dimensionToken: dimensionToken,
            streamDimensions: streamDimensions
        )
        await existingController.beginPostResizeTransition()
        await existingController.updateCadenceTarget(
            sourceFPS: resolvedTargetFrameRate,
            displayFPS: resolvedTargetFrameRate,
            latencyMode: renderLatencyModeByStream[streamID],
            reason: "desktop resize"
        )
        await existingController.updatePresentationTier(
            sessionStore.presentationTier(for: streamID),
            targetFPS: resolvedTargetFrameRate
        )
        decoderCompatibilityFallbackLastAppliedTime[streamID] = 0
        mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
        MirageLogger.client(
            "Prepared existing controller for desktop resize on stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName))"
        )
    }

    internal func applyRenderLatencyMode(
        to streamID: StreamID,
        preferredLatencyMode: MirageStreamLatencyMode? = nil
    ) {
        let latencyMode = preferredLatencyMode ??
            renderLatencyModeByStream[streamID] ??
            .lowestLatency
        renderLatencyModeByStream[streamID] = latencyMode
        MirageRenderStreamStore.shared.setLatencyMode(for: streamID, latencyMode: latencyMode)
    }

    func resolvedRequestedMediaMaxPacketSize() -> Int {
        miragePreferredMediaMaxPacketSize(for: controlPathSnapshot?.kind)
    }

    func resolvedAcceptedMediaMaxPacketSize(_ accepted: Int?) -> Int {
        mirageNegotiatedMediaMaxPacketSize(
            requested: accepted,
            pathKind: controlPathSnapshot?.kind
        )
    }

    package func resolvedDecoderColorDepth(for streamID: StreamID) -> MirageStreamColorDepth {
        decoderCompatibilityCurrentColorDepthByStream[streamID] ??
            decoderCompatibilityBaselineColorDepthByStream[streamID] ??
            .standard
    }

    package func resolvedDecoderBitDepth(for streamID: StreamID) -> MirageVideoBitDepth {
        resolvedDecoderColorDepth(for: streamID).bitDepth
    }

    /// Handle resize event from StreamController.
    private func handleResizeEvent(_ event: StreamController.ResizeEvent, for streamID: StreamID) {
        guard let session = activeStreams.first(where: { $0.id == streamID }) else {
            MirageLogger.error(.client, "No active session for stream \(streamID) during resize")
            return
        }

        let resizeEvent = MirageRelativeResizeEvent(
            windowID: session.window.id,
            aspectRatio: event.aspectRatio,
            relativeScale: event.relativeScale,
            clientScreenSize: event.clientScreenSize,
            pixelWidth: event.pixelWidth,
            pixelHeight: event.pixelHeight
        )

        sendInputFireAndForget(.relativeResize(resizeEvent), forStream: streamID)
    }

    /// Get the controller for a stream (for view access).
    internal func controller(for streamID: StreamID) -> StreamController? {
        controllersByStream[streamID]
    }

    /// Stop viewing a stream.
    /// - Parameters:
    ///   - session: The stream session to stop.
    ///   - minimizeWindow: Whether to minimize the source window on the host (default: false).
    ///   - origin: Optional stop-request origin metadata.
    func stopViewing(
        _ session: ClientStreamSession,
        minimizeWindow: Bool = false,
        origin: MirageClientService.StreamStopOrigin? = nil
    )
    async {
        let streamID = session.id

        let request = StopStreamMessage(
            streamID: streamID,
            minimizeWindow: minimizeWindow,
            origin: origin?.controlMessageOrigin
        )
        if let message = try? ControlMessage(type: .stopStream, content: request) {
            sendControlMessageBestEffort(message)
        }

        await forceStopWindowStreamLocally(streamID: streamID)
    }

    internal func handleTerminalStartupFailure(
        _ failure: StreamController.TerminalStartupFailure,
        for streamID: StreamID
    ) async {
        let waitReason = failure.waitReason ?? "unknown"
        MirageLogger.error(
            .client,
            "Terminal startup failure for stream \(streamID): hardRecoveries=\(failure.hardRecoveryAttempts), " +
                "reason=\(failure.reason.logLabel), waitReason=\(waitReason)"
        )

        let error = MirageError.protocolError(failure.errorMessage)

        if desktopStreamID == streamID {
            if pendingLocalDesktopStopStreamID == streamID,
               pendingLocalDesktopStopSessionID == desktopSessionID {
                MirageLogger.client(
                    "Suppressing terminal startup failure for stream \(streamID) while a local desktop stop is pending"
                )
                await forceStopDesktopStreamLocally(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID,
                    notifyStopReason: .clientRequested
                )
                return
            }

            if await restartDesktopStreamAfterTerminalStartupFailure(failure, failedStreamID: streamID) {
                return
            }

            if let desktopSessionID {
                let request = StopDesktopStreamMessage(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID
                )
                if let message = try? ControlMessage(type: .stopDesktopStream, content: request) {
                    sendControlMessageBestEffort(message)
                }
            }
            await forceStopDesktopStreamLocally(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                notifyStopReason: .error
            )
            delegate?.clientService(self, didEncounterError: error)
            return
        }

        if activeStreams.contains(where: { $0.id == streamID }) || controllersByStream[streamID] != nil {
            let request = StopStreamMessage(
                streamID: streamID,
                minimizeWindow: false,
                origin: nil
            )
            if let message = try? ControlMessage(type: .stopStream, content: request) {
                sendControlMessageBestEffort(message)
            }
            await forceStopWindowStreamLocally(streamID: streamID)
        }

        delegate?.clientService(self, didEncounterError: error)
    }

    internal func handleTerminalLiveRecoveryFailure(
        _ failure: StreamController.TerminalLiveRecoveryFailure,
        for streamID: StreamID
    ) async {
        let waitReason = failure.waitReason ?? "unknown"
        MirageLogger.error(
            .client,
            "Terminal live recovery failure for stream \(streamID): hardRecoveries=\(failure.hardRecoveryAttempts), " +
                "reason=\(failure.reason.logLabel), waitReason=\(waitReason)"
        )

        if desktopStreamID == streamID {
            if await restartDesktopStreamAfterTerminalLiveRecoveryFailure(failure, failedStreamID: streamID) {
                return
            }
            delegate?.clientService(self, didEncounterError: MirageError.protocolError(failure.errorMessage))
            return
        }

        if let session = activeStreams.first(where: { $0.id == streamID }) {
            let bundleIdentifier = session.window.application?.bundleIdentifier
            let recoveryFailure = LiveStreamRecoveryFailure(
                streamID: streamID,
                kind: .app(bundleIdentifier: bundleIdentifier),
                reason: failure.reason.logLabel,
                hardRecoveryAttempts: failure.hardRecoveryAttempts
            )
            onLiveStreamRecoveryFailed?(recoveryFailure)
            return
        }

        let recoveryFailure = LiveStreamRecoveryFailure(
            streamID: streamID,
            kind: .window,
            reason: failure.reason.logLabel,
            hardRecoveryAttempts: failure.hardRecoveryAttempts
        )
        onLiveStreamRecoveryFailed?(recoveryFailure)
    }

    func cancelDesktopStreamStopTimeout() {
        desktopStreamStopTimeoutTask?.cancel()
        desktopStreamStopTimeoutTask = nil
        pendingLocalDesktopStopStreamID = nil
        pendingLocalDesktopStopSessionID = nil
    }

    nonisolated static func shouldForceLocalDesktopStopAfterTimeout(
        requestedStreamID: StreamID,
        requestedDesktopSessionID: UUID,
        activeDesktopStreamID: StreamID?,
        activeDesktopSessionID: UUID?,
        hasController: Bool,
        isRegistered: Bool
    ) -> Bool {
        if let activeDesktopSessionID,
           activeDesktopSessionID != requestedDesktopSessionID {
            return false
        }
        return activeDesktopStreamID == requestedStreamID || hasController || isRegistered
    }

    func scheduleDesktopStreamStopTimeout(for streamID: StreamID, desktopSessionID: UUID) {
        desktopStreamStopTimeoutTask?.cancel()
        desktopStreamStopTimeoutTask = nil
        pendingLocalDesktopStopStreamID = streamID
        pendingLocalDesktopStopSessionID = desktopSessionID
        desktopStreamStopTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.desktopStreamStopTimeout)
            } catch {
                return
            }

            guard Self.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: streamID,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: self.desktopStreamID,
                activeDesktopSessionID: self.desktopSessionID,
                hasController: self.controllersByStream[streamID] != nil,
                isRegistered: self.registeredStreamIDs.contains(streamID)
            ) else {
                self.desktopStreamStopTimeoutTask = nil
                if self.pendingLocalDesktopStopStreamID == streamID,
                   self.pendingLocalDesktopStopSessionID == desktopSessionID {
                    self.pendingLocalDesktopStopStreamID = nil
                    self.pendingLocalDesktopStopSessionID = nil
                }
                return
            }

            MirageLogger.client(
                "Desktop stop acknowledgement timed out for stream \(streamID), session=\(desktopSessionID.uuidString); forcing local teardown"
            )
            await self.forceStopDesktopStreamLocally(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                notifyStopReason: .clientRequested
            )
            self.desktopStreamStopTimeoutTask = nil
        }
    }

    private func forceStopWindowStreamLocally(streamID: StreamID) async {
        recordRetiredStreamDiagnosticsSummary(streamID: streamID, reason: "window:local")
        MirageRenderStreamStore.shared.clear(for: streamID)
        activeStreams.removeAll { $0.id == streamID }
        pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
        renderLatencyModeByStream.removeValue(forKey: streamID)

        metricsStore.clear(streamID: streamID)
        cursorStore.clear(streamID: streamID)
        cursorPositionStore.clear(streamID: streamID)

        removeActiveStreamID(streamID)
        stopVideoStreamReceive(for: streamID)
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

        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.setMediaFeedbackSuspended(true)
            await controller.stop()
        }

        await updateReassemblerSnapshot()
        await refreshSharedClipboardBridgeState()
    }

    func forceStopDesktopStreamLocally(
        streamID: StreamID,
        desktopSessionID expectedDesktopSessionID: UUID? = nil,
        notifyStopReason: DesktopStreamStopReason? = nil
    ) async {
        if let expectedDesktopSessionID,
           let activeDesktopSessionID = desktopSessionID,
           activeDesktopSessionID != expectedDesktopSessionID {
            MirageLogger.client(
                "Skipping local desktop teardown for superseded session \(expectedDesktopSessionID.uuidString); activeSession=\(activeDesktopSessionID.uuidString)"
            )
            return
        }
        if let sessionID = expectedDesktopSessionID ?? desktopSessionID {
            retiredDesktopSessionIDs.insert(sessionID)
        }
        cancelDesktopStreamStopTimeout()
        let hadLocalState = desktopStreamID == streamID ||
            controllersByStream[streamID] != nil ||
            registeredStreamIDs.contains(streamID)

        if hadLocalState {
            recordRetiredStreamDiagnosticsSummary(
                streamID: streamID,
                reason: "desktop:\(notifyStopReason.map(String.init(describing:)) ?? "local")"
            )
        }
        MirageRenderStreamStore.shared.clear(for: streamID)
        pendingApplicationActivationRecoveryStreamIDs.remove(streamID)
        renderLatencyModeByStream.removeValue(forKey: streamID)
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = nil
        desktopStreamRequestStartTime = 0
        if desktopStreamID == streamID {
            desktopStreamID = nil
            desktopSessionID = nil
            desktopStreamResolution = nil
            desktopStreamPresentationResolution = nil
            desktopCaptureSource = .virtualDisplay
            desktopStreamAllowsClientResize = true
            desktopStreamMode = nil
            desktopCursorPresentation = nil
            lastAutomaticDesktopWorkloadReconfigurationSummary = nil
        }
        desktopDimensionTokenByStream.removeValue(forKey: streamID)
        clearStartupAttempt(for: streamID)
        sessionStore.clearPostResizeTransition(for: streamID)
        metricsStore.clear(streamID: streamID)
        cursorStore.clear(streamID: streamID)
        cursorPositionStore.clear(streamID: streamID)
        clearStreamRefreshRateOverride(streamID: streamID)

        removeActiveStreamID(streamID)
        stopVideoStreamReceive(for: streamID)
        registeredStreamIDs.remove(streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupFirstRegistrationSent.remove(streamID)
        streamStartupFirstPacketReceived.remove(streamID)
        clearStartupPacketPending(streamID)
        cancelStartupRegistrationRetry(streamID: streamID)
        cancelRecoveryKeyframeRetry(for: streamID)
        clearDecoderColorDepthState(for: streamID)
        inputEventSender.clearTemporaryPointerCoalescing(for: streamID)
        pendingDesktopRequestedColorDepth = nil
        pendingDesktopRequestedLatencyMode = nil
        activeJitterHoldMs = 0
        mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
        activeStreamCodecs.removeValue(forKey: streamID)

        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.setMediaFeedbackSuspended(true)
            await controller.stop()
        }

        await updateReassemblerSnapshot()
        await refreshSharedClipboardBridgeState()

        if let notifyStopReason, hadLocalState {
            onDesktopStreamStopped?(streamID, notifyStopReason)
        }
    }

    /// Get the minimum window size for a stream (in points).
    func getMinimumSize(forStream streamID: StreamID) -> (minWidth: Int, minHeight: Int)? {
        streamMinSizes[streamID]
    }

    func applyStreamPresentationTier(_ tier: StreamPresentationTier, to streamID: StreamID) async {
        guard let controller = controllersByStream[streamID] else { return }
        let targetFrameRate = resolvedStreamCadenceFrameRate(for: streamID)
        await controller.updatePresentationTier(tier, targetFPS: targetFrameRate)
    }

    func applyHostStreamPolicies(_ policies: [MirageStreamPolicy], epoch: UInt64) async {
        for policy in policies {
            guard let controller = controllersByStream[policy.streamID] else { continue }
            let targetFPS = Self.runtimeWorkloadSafetyCappedFrameRate(
                policy.targetFPS,
                cap: runtimeWorkloadSafetyFrameRateCap(for: policy.streamID)
            )
            await controller.updateCadenceTarget(
                sourceFPS: targetFPS,
                displayFPS: targetFPS,
                latencyMode: renderLatencyModeByStream[policy.streamID],
                reason: "host stream policy"
            )
            await controller.applyHostRuntimePolicy(policy, targetFPS: targetFPS)
        }
        let policyText = policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            let targetFPS = Self.runtimeWorkloadSafetyCappedFrameRate(
                policy.targetFPS,
                cap: runtimeWorkloadSafetyFrameRateCap(for: policy.streamID)
            )
            return "\(policy.streamID)=\(policy.tier.rawValue):\(targetFPS)fps@\(bitrate)"
        }.joined(separator: ", ")
        MirageLogger.client("Applied host stream policy update epoch=\(epoch): [\(policyText)]")
    }
}

private extension MirageClientService.StreamStopOrigin {
    var controlMessageOrigin: StopStreamMessage.Origin {
        switch self {
        case .clientWindowClosed:
            .clientWindowClosed
        case .remoteCommand:
            .remoteCommand
        }
    }
}
