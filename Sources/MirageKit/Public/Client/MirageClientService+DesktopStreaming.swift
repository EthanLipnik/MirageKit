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

@MainActor
public extension MirageClientService {
    /// Start streaming the desktop (mirrored or secondary display mode).
    /// - Parameters:
    ///   - quality: Quality preset for the stream.
    ///   - scaleFactor: Optional display scale factor.
    ///   - displayResolution: Client's display resolution for virtual display sizing.
    ///   - mode: Desktop stream mode (mirrored vs secondary display).
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - captureSource: Optional desktop capture source override.
    // TODO: HDR support - requires proper virtual display EDR configuration.
    // ///   - preferHDR: Whether to request HDR streaming (Rec. 2020 with PQ).
    func startDesktopStream(
        quality: MirageQualityPreset = .medium,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        mode: MirageDesktopStreamMode = .mirrored,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        captureSource: MirageDesktopCaptureSource? = nil
        // preferHDR: Bool = false
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        // Use provided display resolution or detect from main display.
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())

        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else { throw MirageError.protocolError("Invalid display resolution") }

        desktopStreamMode = mode

        var request = StartDesktopStreamMessage(
            preferredQuality: quality,
            scaleFactor: scaleFactor,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            keyFrameInterval: nil,
            frameQuality: nil,
            keyframeQuality: nil,
            pixelFormat: nil,
            colorSpace: nil,
            captureSource: captureSource,
            mode: mode,
            minBitrate: nil,
            maxBitrate: nil,
            streamScale: clampedStreamScale(),
            latencyMode: latencyMode,
            dataPort: nil,
            maxRefreshRate: getScreenMaxRefreshRate()
        )
        // TODO: HDR support - requires proper virtual display EDR configuration.
        // request.preferHDR = preferHDR

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        if overrides.frameQuality == nil { overrides.frameQuality = keyframeQuality }
        applyEncoderOverrides(overrides, to: &request)

        if let captureSource { MirageLogger.client("Requesting desktop capture source: \(captureSource.displayName)") }

        let message = try ControlMessage(type: .startDesktopStream, content: request)
        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()
        MirageLogger.client("Desktop start: request sent")
        connection.send(content: message.serialize(), completion: .idempotent)

        MirageLogger
            .client(
                "Requested desktop stream: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))"
            )
    }

    /// Stop the current desktop stream.
    func stopDesktopStream() async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        guard let streamID = desktopStreamID else {
            MirageLogger.client("No active desktop stream to stop")
            return
        }

        let request = StopDesktopStreamMessage(streamID: streamID)
        let message = try ControlMessage(type: .stopDesktopStream, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        MirageLogger.client("Requested stop desktop stream: \(streamID)")
    }
}
