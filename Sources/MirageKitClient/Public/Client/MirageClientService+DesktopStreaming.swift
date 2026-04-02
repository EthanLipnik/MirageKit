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
    /// Start streaming the desktop (mirrored or secondary display mode).
    /// - Parameters:
    ///   - scaleFactor: Optional display scale factor.
    ///   - displayResolution: Client's logical display size in points for virtual display sizing.
    ///   - mode: Desktop stream mode (mirrored vs secondary display).
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    func startDesktopStream(
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        mode: MirageDesktopStreamMode = .mirrored,
        cursorPresentation: MirageDesktopCursorPresentation = .clientCursor,
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
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation

        let resolvedAudioConfiguration = (audioConfiguration ?? self.audioConfiguration)
            .resolvedForDesktopStreamMode(mode)

        var encoderRequest = StartDesktopStreamMessage(
            scaleFactor: nil,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            keyFrameInterval: nil,
            mode: mode,
            cursorPresentation: cursorPresentation,
            bitrate: nil,
            streamScale: nil,
            audioConfiguration: resolvedAudioConfiguration,
            dataPort: nil,
            useHostResolution: useHostResolution ? true : nil,
            maxRefreshRate: getScreenMaxRefreshRate(),
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
        let scaledBitrate: Int?
        if encoderRequest.bitrateAdaptationCeiling != nil {
            scaledBitrate = encoderRequest.bitrate
        } else if let bitrate = encoderRequest.bitrate, bitrate > 0 {
            let baselinePixels: Double = 2560.0 * 1440.0
            let scaleFactor = min(
                max(
                    Double(geometry.displayPixelSize.width) * Double(geometry.displayPixelSize.height) / baselinePixels,
                    1.0
                ),
                2.0
            )
            scaledBitrate = Int(Double(bitrate) * scaleFactor)
        } else {
            scaledBitrate = nil
        }
        var request = StartDesktopStreamMessage(
            scaleFactor: geometry.displayScaleFactor,
            displayWidth: encoderRequest.displayWidth,
            displayHeight: encoderRequest.displayHeight,
            streamScale: geometry.resolvedStreamScale,
            audioConfiguration: encoderRequest.audioConfiguration,
            dataPort: encoderRequest.dataPort,
            useHostResolution: encoderRequest.useHostResolution,
            maxRefreshRate: encoderRequest.maxRefreshRate
        )
        request.keyFrameInterval = encoderRequest.keyFrameInterval
        request.captureQueueDepth = encoderRequest.captureQueueDepth
        request.colorDepth = encoderRequest.colorDepth
        request.mode = encoderRequest.mode
        request.cursorPresentation = encoderRequest.cursorPresentation
        request.bitrate = scaledBitrate
        request.latencyMode = encoderRequest.latencyMode
        request.performanceMode = encoderRequest.performanceMode
        request.allowRuntimeQualityAdjustment = encoderRequest.allowRuntimeQualityAdjustment
        request.lowLatencyHighResolutionCompressionBoost = encoderRequest.lowLatencyHighResolutionCompressionBoost
        request.temporaryDegradationMode = encoderRequest.temporaryDegradationMode
        request.disableResolutionCap = encoderRequest.disableResolutionCap
        request.bitrateAdaptationCeiling = encoderRequest.bitrateAdaptationCeiling
        request.encoderMaxWidth = encoderRequest.encoderMaxWidth
        request.encoderMaxHeight = encoderRequest.encoderMaxHeight
        request.mediaMaxPacketSize = encoderRequest.mediaMaxPacketSize
        request.upscalingMode = encoderRequest.upscalingMode
        request.codec = encoderRequest.codec
        pendingDesktopRequestedColorDepth = request.colorDepth

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

    private static let desktopStreamStartTimeoutSeconds: Double = 75

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
            MirageLogger.client("No active desktop stream to stop")
            return
        }

        let request = StopDesktopStreamMessage(streamID: streamID)
        try await sendControlMessage(.stopDesktopStream, content: request)

        MirageLogger.client("Requested stop desktop stream: \(streamID)")
    }
}
