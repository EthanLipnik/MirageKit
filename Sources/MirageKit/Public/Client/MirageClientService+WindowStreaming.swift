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

@MainActor
extension MirageClientService {
    /// Start viewing a remote window.
    /// - Parameters:
    ///   - window: The remote window to stream.
    ///   - quality: Quality preset for the stream.
    ///   - expectedPixelSize: Optional pixel dimensions the client expects to render at.
    ///     If provided, the host will encode at this resolution from the start.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///     Used with expectedPixelSize to calculate point-based window size.
    ///   - displayResolution: Client's physical display resolution in pixels.
    ///     If provided, host creates a virtual display at this resolution for optimal quality.
    ///   - keyFrameInterval: Optional keyframe interval in frames. Higher = fewer lag spikes.
    ///     Examples: 600 (10 seconds @ 60fps), 300 (5 seconds @ 60fps).
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0). Lower = smaller frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    public func startViewing(
        window: MirageWindow,
        quality: MirageQualityPreset = .medium,
        expectedPixelSize: CGSize? = nil,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
    ) async throws -> ClientStreamSession {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        // Note: Decoder/reassembler are created per-stream AFTER receiving streamStarted with the stream ID.
        var request = StartStreamMessage(windowID: window.id, preferredQuality: quality, dataPort: nil)
        if let expectedPixelSize, expectedPixelSize.width > 0, expectedPixelSize.height > 0 {
            request.pixelWidth = Int(expectedPixelSize.width)
            request.pixelHeight = Int(expectedPixelSize.height)
            request.scaleFactor = scaleFactor
        }

        // Include display resolution for virtual display sizing.
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())
        if effectiveDisplayResolution.width > 0 && effectiveDisplayResolution.height > 0 {
            request.displayWidth = Int(effectiveDisplayResolution.width)
            request.displayHeight = Int(effectiveDisplayResolution.height)
            MirageLogger.client("Including display resolution: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))")
        }

        // Include encoder config overrides if specified.
        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil {
            overrides.keyFrameInterval = keyFrameInterval
        }
        if overrides.frameQuality == nil {
            overrides.frameQuality = keyframeQuality
        }
        applyEncoderOverrides(overrides, to: &request)

        request.streamScale = clampedStreamScale()
        request.adaptiveScaleEnabled = adaptiveScaleEnabled
        request.latencyMode = latencyMode
        request.maxRefreshRate = getScreenMaxRefreshRate()

        let message = try ControlMessage(type: .startStream, content: request)
        let messageData = message.serialize()

        MirageLogger.client("Sending startStream for window \(window.id)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: messageData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Wait for streamStarted response from server to get the real stream ID.
        let realStreamID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StreamID, Error>) in
            self.streamStartedContinuation = continuation
        }

        MirageLogger.client("Stream started with ID \(realStreamID)")

        // Create per-stream controller (owns decoder and reassembler).
        await setupControllerForStream(realStreamID)

        // Add to active streams set (thread-safe for packet filtering).
        addActiveStreamID(realStreamID)

        let session = ClientStreamSession(
            id: realStreamID,
            window: window,
            quality: quality
        )

        activeStreams.append(session)
        return session
    }

    /// Set up or reset controller for a specific stream.
    /// StreamController owns the decoder, reassembler, and resize state machine.
    func setupControllerForStream(_ streamID: StreamID) async {
        if let existingController = controllersByStream[streamID] {
            await existingController.resetForNewSession()
            MirageLogger.client("Reset existing controller for stream \(streamID)")
            return
        }

        let payloadSize = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        let controller = StreamController(streamID: streamID, maxPayloadSize: payloadSize)
        controllersByStream[streamID] = controller

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
                self.metricsStore.updateClientMetrics(
                    streamID: capturedStreamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    droppedFrames: metrics.droppedFrames
                )
            },
            onFirstFrame: { [weak self] in
                self?.sessionStore.markFirstFrameReceived(for: capturedStreamID)
            },
            onInputBlockingChanged: { [weak self] isBlocked in
                self?.setInputBlocked(isBlocked, for: capturedStreamID)
            }
        )

        await controller.start()
        await updateReassemblerSnapshot()

        MirageLogger.client("Created new controller for stream \(streamID)")
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
    func controller(for streamID: StreamID) -> StreamController? {
        controllersByStream[streamID]
    }

    /// Stop viewing a stream.
    /// - Parameters:
    ///   - session: The stream session to stop.
    ///   - minimizeWindow: Whether to minimize the source window on the host (default: false).
    public func stopViewing(_ session: ClientStreamSession, minimizeWindow: Bool = false) async {
        let streamID = session.id

        MirageFrameCache.shared.clear(for: streamID)

        let request = StopStreamMessage(streamID: streamID, minimizeWindow: minimizeWindow)
        if let message = try? ControlMessage(type: .stopStream, content: request),
           let connection {
            connection.send(content: message.serialize(), completion: .idempotent)
        }

        activeStreams.removeAll { $0.id == streamID }

        removeActiveStreamID(streamID)
        registeredStreamIDs.remove(streamID)
        clearStreamRefreshRateOverride(streamID: streamID)

        if let controller = controllersByStream[streamID] {
            await controller.stop()
            controllersByStream.removeValue(forKey: streamID)
        }

        await updateReassemblerSnapshot()
    }

    /// Get the minimum window size for a stream (in points).
    public func getMinimumSize(forStream streamID: StreamID) -> (minWidth: Int, minHeight: Int)? {
        streamMinSizes[streamID]
    }
}
