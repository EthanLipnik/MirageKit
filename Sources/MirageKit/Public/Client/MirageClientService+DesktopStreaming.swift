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
    ///   - scaleFactor: Optional display scale factor.
    ///   - displayResolution: Client's display resolution for virtual display sizing.
    ///   - mode: Desktop stream mode (mirrored vs secondary display).
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    // TODO: HDR support - requires proper virtual display EDR configuration.
    // ///   - preferHDR: Whether to request HDR streaming (Rec. 2020 with PQ).
    func startDesktopStream(
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        mode: MirageDesktopStreamMode = .mirrored,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
        // preferHDR: Bool = false
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        // Use provided display resolution or detect from main display.
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())

        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else { throw MirageError.protocolError("Invalid display resolution") }

        desktopStreamMode = mode

        var request = StartDesktopStreamMessage(
            scaleFactor: scaleFactor,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            keyFrameInterval: nil,
            pixelFormat: nil,
            colorSpace: nil,
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
        applyEncoderOverrides(overrides, to: &request)

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
