//
//  MirageClientService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Desktop streaming requests.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Start streaming the desktop (unified or secondary display mode).
    /// - Parameters:
    ///   - scaleFactor: Optional display scale factor.
    ///   - displayResolution: Client's logical display size in points for virtual display sizing.
    ///   - mode: Desktop stream mode (unified vs secondary display).
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    func startDesktopStream(
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        mode: MirageDesktopStreamMode = .unified,
        cursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        useHostResolution: Bool = false
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        await cancelActiveQualityTest(
            reason: "interactive desktop stream startup",
            notifyHost: true
        )

        let baseResolution = displayResolution ?? getMainDisplayResolution()
        guard baseResolution.width > 0, baseResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable")
        }
        let effectiveDisplayResolution = scaledDisplayResolution(baseResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Invalid display resolution")
        }
        let targetFrameRate = getScreenMaxRefreshRate()
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation

        let resolvedAudioConfiguration = (audioConfiguration ?? self.audioConfiguration)
            .resolvedForDesktopStreamMode(mode)
        MirageLogger.client(
            "Desktop stream audio request: enabled=\(resolvedAudioConfiguration.enabled), " +
                "layout=\(resolvedAudioConfiguration.channelLayout.rawValue), " +
                "quality=\(resolvedAudioConfiguration.quality.rawValue), mode=\(mode.rawValue)"
        )

        let startupRequestID = UUID()
        pendingStreamSetupRequestID = startupRequestID
        pendingStreamSetupKind = .desktop
        pendingStreamSetupAppSessionID = nil

        var encoderRequest = StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: nil,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            targetFrameRate: targetFrameRate,
            keyFrameInterval: nil,
            mode: mode,
            cursorPresentation: cursorPresentation,
            bitrate: nil,
            streamScale: nil,
            audioConfiguration: resolvedAudioConfiguration,
            dataPort: nil,
            useHostResolution: useHostResolution ? true : nil,
            mediaMaxPacketSize: resolvedRequestedMediaMaxPacketSize()
        )

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &encoderRequest)
        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor,
            requestedStreamScale: clampedStreamScale(),
            encoderMaxWidth: encoderRequest.encoderMaxWidth,
            encoderMaxHeight: encoderRequest.encoderMaxHeight,
            disableResolutionCap: encoderRequest.disableResolutionCap == true
        )
        resolutionScale = geometry.resolvedStreamScale
        desktopResizeCoordinator.lastSentTarget = DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: effectiveDisplayResolution,
            displayScaleFactor: geometry.displayScaleFactor,
            requestedStreamScale: geometry.resolvedStreamScale,
            encoderMaxWidth: encoderRequest.encoderMaxWidth,
            encoderMaxHeight: encoderRequest.encoderMaxHeight
        )
        let bitrateSemantics = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: encoderRequest.enteredBitrate,
            requestedTargetBitrateBps: encoderRequest.bitrate,
            bitrateAdaptationCeilingBps: encoderRequest.bitrateAdaptationCeiling,
            displayResolution: effectiveDisplayResolution
        )
        var request = StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: geometry.displayScaleFactor,
            displayWidth: encoderRequest.displayWidth,
            displayHeight: encoderRequest.displayHeight,
            targetFrameRate: encoderRequest.targetFrameRate,
            streamScale: geometry.resolvedStreamScale,
            audioConfiguration: encoderRequest.audioConfiguration,
            dataPort: encoderRequest.dataPort,
            useHostResolution: encoderRequest.useHostResolution,
            mediaMaxPacketSize: encoderRequest.mediaMaxPacketSize
        )
        request.keyFrameInterval = encoderRequest.keyFrameInterval
        request.captureQueueDepth = encoderRequest.captureQueueDepth
        request.colorDepth = encoderRequest.colorDepth
        request.mode = encoderRequest.mode
        request.cursorPresentation = encoderRequest.cursorPresentation
        request.enteredBitrate = bitrateSemantics.enteredBitrateBps
        request.bitrate = bitrateSemantics.requestedTargetBitrateBps
        request.latencyMode = encoderRequest.latencyMode
        request.allowRuntimeQualityAdjustment = encoderRequest.allowRuntimeQualityAdjustment
        request.lowLatencyHighResolutionCompressionBoost = encoderRequest.lowLatencyHighResolutionCompressionBoost
        request.disableResolutionCap = encoderRequest.disableResolutionCap
        request.bitrateAdaptationCeiling = bitrateSemantics.bitrateAdaptationCeilingBps
        request.encoderMaxWidth = encoderRequest.encoderMaxWidth
        request.encoderMaxHeight = encoderRequest.encoderMaxHeight
        request.upscalingMode = encoderRequest.upscalingMode
        request.codec = encoderRequest.codec
        pendingDesktopRequestedColorDepth = request.colorDepth
        pendingDesktopRequestedLatencyMode = request.latencyMode ?? .lowestLatency
        pendingStreamSetupLatencyMode = request.latencyMode ?? .lowestLatency
        desktopStreamRestartAttempts = 0
        lastDesktopStreamStartRequest = request

        let enteredBitrateText = request.enteredBitrate.map(Self.formatBitrateForLogging) ?? "n/a"
        let requestedBitrateText = request.bitrate.map(Self.formatBitrateForLogging) ?? "auto"
        let ceilingText = request.bitrateAdaptationCeiling.map(Self.formatBitrateForLogging) ?? "none"
        MirageLogger.client(
            "Desktop bitrate contract requested: entered=\(enteredBitrateText) requested=\(requestedBitrateText) ceiling=\(ceilingText) " +
                "scale=\(String(format: "%.3f", bitrateSemantics.geometryScaleFactor)) display=\(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))"
        )

        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()
        MirageLogger.client("Desktop start: request sent")
        try await sendControlMessage(.startDesktopStream, content: request)
        // Desktop startup shares the same control channel as metadata refreshes,
        // startup acks, and refresh-override traffic. Extend heartbeat grace so
        // we do not tear down the control session while startup control work is
        // still in flight.
        heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
        scheduleDesktopStreamStartTimeout()

        MirageLogger
            .client(
                "Requested desktop stream: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height)) pts " +
                    "(\(Int(geometry.displayPixelSize.width))x\(Int(geometry.displayPixelSize.height)) px, " +
                    "encode \(Int(geometry.encodedPixelSize.width))x\(Int(geometry.encodedPixelSize.height)) px, " +
                    "scale \(String(format: "%.3f", geometry.displayScaleFactor))x, " +
                    "stream \(String(format: "%.3f", geometry.resolvedStreamScale)))"
            )
    }

    private static func formatBitrateForLogging(_ bitrate: Int) -> String {
        (Double(bitrate) / 1_000_000.0).formatted(.number.precision(.fractionLength(1))) + "Mbps"
    }

    func sendDesktopCursorPresentationChange(
        streamID: StreamID,
        cursorPresentation: MirageDesktopCursorPresentation
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        let request = DesktopCursorPresentationChangeMessage(
            streamID: streamID,
            cursorPresentation: cursorPresentation
        )
        try await sendControlMessage(.desktopCursorPresentationChange, content: request)
        desktopCursorPresentation = cursorPresentation
    }

    private static let desktopStreamStartTimeoutSeconds: Double = 30

    private func scheduleDesktopStreamStartTimeout() {
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(Self.desktopStreamStartTimeoutSeconds))
            guard let self else { return }
            guard desktopStreamMode != nil, desktopStreamID == nil,
                  desktopStreamRequestStartTime > 0 else { return }
            MirageLogger.error(
                .client,
                "Desktop stream start timed out after \(Int(Self.desktopStreamStartTimeoutSeconds))s"
            )
            cancelStreamSetup()
            clearPendingDesktopStreamStartState()
            delegate?.clientService(
                self,
                didEncounterError: MirageError.protocolError("Desktop stream start timed out. The host may be busy or unreachable.")
            )
        }
    }

    /// Stop the current desktop stream.
    func stopDesktopStream() async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        guard let streamID = desktopStreamID else {
            cancelDesktopStreamStopTimeout()
            MirageLogger.client("No active desktop stream to stop")
            return
        }

        guard let desktopSessionID else {
            throw MirageError.protocolError("Desktop stream missing session identifier")
        }

        let request = StopDesktopStreamMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID
        )
        pendingLocalDesktopStopStreamID = streamID
        pendingLocalDesktopStopSessionID = desktopSessionID
        clearDesktopResizeState(streamID: streamID)

        do {
            try await sendControlMessage(.stopDesktopStream, content: request)
        } catch {
            if pendingLocalDesktopStopStreamID == streamID,
               pendingLocalDesktopStopSessionID == desktopSessionID {
                cancelDesktopStreamStopTimeout()
            }
            throw error
        }

        scheduleDesktopStreamStopTimeout(for: streamID, desktopSessionID: desktopSessionID)

        MirageLogger.client(
            "Requested stop desktop stream: stream=\(streamID), session=\(desktopSessionID.uuidString)"
        )
    }

    internal func hasDesktopStreamRestartBudget(streamID: StreamID) -> Bool {
        desktopStreamID == streamID &&
            lastDesktopStreamStartRequest != nil &&
            desktopStreamRestartAttempts < desktopStreamRestartLimit
    }

    internal func canRestartDesktopStreamAfterTerminalStartupFailure(streamID: StreamID) -> Bool {
        guard case .connected = connectionState,
              controlChannel != nil,
              hasDesktopStreamRestartBudget(streamID: streamID) else {
            return false
        }
        return true
    }

    package func makeDesktopStreamRestartRequest(
        from request: StartDesktopStreamMessage,
        startupRequestID: UUID = UUID()
    ) -> StartDesktopStreamMessage {
        var restarted = StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: request.scaleFactor,
            displayWidth: request.displayWidth,
            displayHeight: request.displayHeight,
            targetFrameRate: request.targetFrameRate,
            streamScale: request.streamScale,
            audioConfiguration: request.audioConfiguration,
            dataPort: request.dataPort,
            useHostResolution: request.useHostResolution,
            mediaMaxPacketSize: request.mediaMaxPacketSize
        )
        restarted.keyFrameInterval = request.keyFrameInterval
        restarted.captureQueueDepth = request.captureQueueDepth
        restarted.colorDepth = request.colorDepth
        restarted.mode = request.mode
        restarted.cursorPresentation = request.cursorPresentation
        restarted.enteredBitrate = request.enteredBitrate
        restarted.bitrate = request.bitrate
        restarted.latencyMode = request.latencyMode
        restarted.allowRuntimeQualityAdjustment = request.allowRuntimeQualityAdjustment
        restarted.lowLatencyHighResolutionCompressionBoost = request.lowLatencyHighResolutionCompressionBoost
        restarted.disableResolutionCap = request.disableResolutionCap
        restarted.bitrateAdaptationCeiling = request.bitrateAdaptationCeiling
        restarted.encoderMaxWidth = request.encoderMaxWidth
        restarted.encoderMaxHeight = request.encoderMaxHeight
        restarted.upscalingMode = request.upscalingMode
        restarted.codec = request.codec
        return restarted
    }

    internal func restartDesktopStreamAfterTerminalStartupFailure(
        _ failure: StreamController.TerminalStartupFailure,
        failedStreamID: StreamID
    ) async -> Bool {
        guard canRestartDesktopStreamAfterTerminalStartupFailure(streamID: failedStreamID),
              let previousRequest = lastDesktopStreamStartRequest else {
            return false
        }

        let failedDesktopSessionID = desktopSessionID
        let restartRequest = makeDesktopStreamRestartRequest(from: previousRequest)
        desktopStreamRestartAttempts += 1
        MirageLogger.client(
            "Restarting desktop stream in-session after terminal startup failure: " +
                "failedStream=\(failedStreamID), attempt=\(desktopStreamRestartAttempts)/\(desktopStreamRestartLimit), " +
                "reason=\(failure.reason.logLabel), startupRequest=\(restartRequest.startupRequestID.uuidString)"
        )

        if let failedDesktopSessionID {
            let stopRequest = StopDesktopStreamMessage(
                streamID: failedStreamID,
                desktopSessionID: failedDesktopSessionID
            )
            _ = sendControlMessageBestEffort(.stopDesktopStream, content: stopRequest)
        }

        await forceStopDesktopStreamLocally(
            streamID: failedStreamID,
            desktopSessionID: failedDesktopSessionID,
            notifyStopReason: nil
        )

        guard case .connected = connectionState else { return false }

        lastDesktopStreamStartRequest = restartRequest
        pendingStreamSetupRequestID = restartRequest.startupRequestID
        pendingStreamSetupKind = .desktop
        pendingStreamSetupAppSessionID = nil
        pendingStreamSetupLatencyMode = restartRequest.latencyMode ?? .lowestLatency
        pendingDesktopRequestedColorDepth = restartRequest.colorDepth
        pendingDesktopRequestedLatencyMode = restartRequest.latencyMode ?? .lowestLatency
        desktopStreamMode = restartRequest.mode ?? .unified
        desktopCursorPresentation = restartRequest.cursorPresentation
        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        do {
            try await sendControlMessage(.startDesktopStream, content: restartRequest)
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            scheduleDesktopStreamStartTimeout()
            MirageLogger.client(
                "Desktop restart: request sent after terminal startup failure for stream \(failedStreamID)"
            )
            return true
        } catch {
            MirageLogger.error(.client, error: error, message: "Desktop restart failed after terminal startup failure: ")
            clearPendingDesktopStreamStartState()
            return false
        }
    }

    /// Cancel any in-progress stream setup on the host.
    /// Used when the user cancels during loading before a stream ID is established.
    func cancelStreamSetup() {
        guard case .connected = connectionState else { return }
        _ = sendControlMessageBestEffort(
            .cancelStreamSetup,
            content: CancelStreamSetupMessage(
                startupRequestID: pendingStreamSetupRequestID,
                kind: pendingStreamSetupKind,
                appSessionID: pendingStreamSetupAppSessionID
            )
        )
        pendingStreamSetupRequestID = nil
        pendingStreamSetupKind = nil
        pendingStreamSetupAppSessionID = nil
        pendingStreamSetupLatencyMode = nil
        MirageLogger.client("Sent cancel stream setup")
    }
}
