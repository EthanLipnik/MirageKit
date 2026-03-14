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

        // Note: Decoder/reassembler are created per-stream AFTER receiving streamStarted with the stream ID.
        var request = StartStreamMessage(windowID: window.id, dataPort: nil)
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for window streaming")
        }
        let resolvedScaleFactor = resolvedDisplayScaleFactor(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor
        )
        request.scaleFactor = resolvedScaleFactor
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
        if let bitrate = request.bitrate, bitrate > 0 {
            pendingAdaptiveFallbackBitrateByWindowID[window.id] = bitrate
        } else {
            pendingAdaptiveFallbackBitrateByWindowID.removeValue(forKey: window.id)
        }
        if let colorDepth = request.colorDepth {
            pendingAdaptiveFallbackColorDepthByWindowID[window.id] = colorDepth
        } else {
            pendingAdaptiveFallbackColorDepthByWindowID.removeValue(forKey: window.id)
        }

        request.streamScale = clampedStreamScale()
        request.audioConfiguration = audioConfiguration ?? self.audioConfiguration
        request.maxRefreshRate = getScreenMaxRefreshRate()

        MirageLogger.client("Sending startStream for window \(window.id)")
        try await sendControlMessage(.startStream, content: request)

        // Wait for streamStarted response from server to get the real stream ID.
        let realStreamID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            StreamID,
            Error
        >) in
            self.streamStartedContinuation = continuation
        }
        let pendingBitrate = pendingAdaptiveFallbackBitrateByWindowID.removeValue(forKey: window.id)
        let pendingColorDepth = pendingAdaptiveFallbackColorDepthByWindowID.removeValue(forKey: window.id)
        configureAdaptiveFallbackBaseline(
            for: realStreamID,
            bitrate: pendingBitrate,
            colorDepth: pendingColorDepth
        )

        MirageLogger.client("Stream started with ID \(realStreamID)")

        // Create per-stream controller (owns decoder and reassembler).
        await setupControllerForStream(realStreamID)

        // Add to active streams set (thread-safe for packet filtering).
        addActiveStreamID(realStreamID)

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
        beginPostResizeTransition: Bool = false
    )
    async {
        let preferredDecoderBitDepth = resolvedDecoderBitDepth(for: streamID)

        if let existingController = controllersByStream[streamID] {
            await existingController.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
            await existingController.setPreferredDecoderBitDepth(preferredDecoderBitDepth)
            await existingController.resetForNewSession()
            if beginPostResizeTransition {
                await existingController.beginPostResizeTransition()
            }
            let tier = sessionStore.presentationTier(for: streamID)
            await existingController.updatePresentationTier(tier)
            adaptiveFallbackLastAppliedTime[streamID] = 0
            MirageLogger
                .client(
                    "Reset existing controller for stream \(streamID) (decoder bit depth \(preferredDecoderBitDepth.displayName))"
                )
            return
        }

        let payloadSize = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        let controller = StreamController(streamID: streamID, maxPayloadSize: payloadSize)
        controllersByStream[streamID] = controller
        if adaptiveFallbackBaselineBitrateByStream[streamID] == nil,
           adaptiveFallbackBaselineColorDepthByStream[streamID] == nil,
           (pendingAppAdaptiveFallbackBitrate != nil ||
                pendingAppAdaptiveFallbackColorDepth != nil) {
            configureAdaptiveFallbackBaseline(
                for: streamID,
                bitrate: pendingAppAdaptiveFallbackBitrate,
                colorDepth: pendingAppAdaptiveFallbackColorDepth
            )
        }
        adaptiveFallbackLastAppliedTime[streamID] = 0

        await controller.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
        await controller.setPreferredDecoderBitDepth(preferredDecoderBitDepth)

        let capturedStreamID = streamID
        await controller.setCallbacks(
            onKeyframeNeeded: { [weak self] in
                self?.sendKeyframeRequest(for: capturedStreamID)
            },
            onResizeEvent: { [weak self] event in
                self?.handleResizeEvent(event, for: capturedStreamID)
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self] metrics in
                guard let self else { return }
                metricsStore.updateClientMetrics(
                    streamID: capturedStreamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    droppedFrames: metrics.droppedFrames,
                    presentedFPS: metrics.presentedFPS,
                    uniquePresentedFPS: metrics.uniquePresentedFPS,
                    renderBufferDepth: metrics.renderBufferDepth,
                    decodeHealthy: metrics.decodeHealthy
                )
                self.activeJitterHoldMs = metrics.activeJitterHoldMs
                self.logAwdlExperimentTelemetryIfNeeded()
            },
            onFirstFrameDecoded: { [weak self] in
                self?.sessionStore.markFirstFrameDecoded(for: capturedStreamID)
            },
            onFirstFramePresented: { [weak self] in
                self?.sessionStore.markFirstFramePresented(for: capturedStreamID)
            },
            onAdaptiveFallbackNeeded: { [weak self] in
                self?.handleAdaptiveFallbackTrigger(for: capturedStreamID)
            },
            onStallEvent: { [weak self] in
                guard let self else { return }
                self.stallEvents &+= 1
                self.inputEventSender.activateTemporaryPointerCoalescing(for: capturedStreamID, duration: 1.2)
                self.logAwdlExperimentTelemetryIfNeeded()
            }
        )

        await controller.updateDecodeSubmissionLimit(targetFrameRate: getScreenMaxRefreshRate())
        if let kind = videoPathSnapshot?.kind {
            await controller.setTransportPathKind(kind)
        }
        if beginPostResizeTransition {
            await controller.beginPostResizeTransition()
        }
        await controller.start()
        await controller.updatePresentationTier(sessionStore.presentationTier(for: streamID))
        await updateReassemblerSnapshot()

        MirageLogger
            .client(
                "Created new controller for stream \(streamID) (decoder bit depth \(preferredDecoderBitDepth.displayName))"
            )
    }

    package func resolvedDecoderBitDepth(for streamID: StreamID) -> MirageVideoBitDepth {
        adaptiveFallbackColorDepthByStream[streamID]?.bitDepth ??
            adaptiveFallbackBaselineColorDepthByStream[streamID]?.bitDepth ??
            .eightBit
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

        MirageFrameCache.shared.clear(for: streamID)

        let request = StopStreamMessage(
            streamID: streamID,
            minimizeWindow: minimizeWindow,
            origin: origin?.controlMessageOrigin
        )
        if let message = try? ControlMessage(type: .stopStream, content: request) {
            _ = sendControlMessageBestEffort(message)
        }

        activeStreams.removeAll { $0.id == streamID }

        removeActiveStreamID(streamID)
        registeredStreamIDs.remove(streamID)
        clearStreamRefreshRateOverride(streamID: streamID)
        inputEventSender.clearTemporaryPointerCoalescing(for: streamID)

        if let controller = controllersByStream[streamID] {
            await controller.stop()
            controllersByStream.removeValue(forKey: streamID)
        }
        clearAdaptiveFallbackState(for: streamID)

        await updateReassemblerSnapshot()
    }

    /// Get the minimum window size for a stream (in points).
    func getMinimumSize(forStream streamID: StreamID) -> (minWidth: Int, minHeight: Int)? {
        streamMinSizes[streamID]
    }

    func applyStreamPresentationTier(_ tier: StreamPresentationTier, to streamID: StreamID) async {
        guard let controller = controllersByStream[streamID] else { return }
        await controller.updatePresentationTier(tier)
    }

    func applyHostStreamPolicies(_ policies: [MirageStreamPolicy], epoch: UInt64) async {
        for policy in policies {
            guard let controller = controllersByStream[policy.streamID] else { continue }
            await controller.applyHostRuntimePolicy(policy)
        }
        let policyText = policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            return "\(policy.streamID)=\(policy.tier.rawValue):\(policy.targetFPS)fps@\(bitrate)"
        }.joined(separator: ", ")
        MirageLogger.client("Applied host stream policy update epoch=\(epoch): [\(policyText)]")
    }
}

private extension MirageClientService.StreamStopOrigin {
    var controlMessageOrigin: StopStreamMessage.Origin {
        switch self {
        case .clientWindowClosed:
            .clientWindowClosed
        }
    }
}
