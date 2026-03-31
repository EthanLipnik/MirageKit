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
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        useHostResolution: Bool = false
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let baseResolution = displayResolution ?? getMainDisplayResolution()
        guard baseResolution.width > 0, baseResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable")
        }
        let effectiveDisplayResolution = scaledDisplayResolution(baseResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Invalid display resolution")
        }
        let effectiveDisplayPixelResolution = virtualDisplayPixelResolution(for: effectiveDisplayResolution)
        let resolvedScaleFactor: CGFloat? = {
            if let scaleFactor, scaleFactor > 0 {
                return scaleFactor
            }
            guard effectiveDisplayResolution.width > 0,
                  effectiveDisplayResolution.height > 0,
                  effectiveDisplayPixelResolution.width > 0,
                  effectiveDisplayPixelResolution.height > 0 else {
                return nil
            }
            let widthScale = effectiveDisplayPixelResolution.width / effectiveDisplayResolution.width
            let heightScale = effectiveDisplayPixelResolution.height / effectiveDisplayResolution.height
            let resolvedScale: CGFloat = if widthScale > 0, heightScale > 0 {
                (widthScale + heightScale) / 2.0
            } else {
                max(widthScale, heightScale)
            }
            guard resolvedScale > 0 else { return nil }
            return resolvedScale
        }()

        desktopStreamMode = mode

        var request = StartDesktopStreamMessage(
            scaleFactor: resolvedScaleFactor,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            keyFrameInterval: nil,
            mode: mode,
            bitrate: nil,
            streamScale: clampedStreamScale(),
            audioConfiguration: audioConfiguration ?? self.audioConfiguration,
            dataPort: nil,
            useHostResolution: useHostResolution ? true : nil,
            maxRefreshRate: getScreenMaxRefreshRate()
        )

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &request)
        if let bitrate = request.bitrate, bitrate > 0 {
            pendingDesktopAdaptiveFallbackBitrate = bitrate
        } else {
            pendingDesktopAdaptiveFallbackBitrate = nil
        }
        pendingDesktopAdaptiveFallbackColorDepth = request.colorDepth

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
                    "(\(Int(effectiveDisplayPixelResolution.width))x\(Int(effectiveDisplayPixelResolution.height)) px)"
            )
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
