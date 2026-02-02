//
//  MirageClientService+AppStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App-centric streaming requests.
//

import CoreGraphics
import Foundation

@MainActor
public extension MirageClientService {
    /// Request list of installed apps from host.
    /// - Parameter includeIcons: Whether to include app icons (increases message size).
    func requestAppList(includeIcons: Bool = true) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        MirageLogger.client("Requesting app list from host (includeIcons: \(includeIcons))")
        let request = AppListRequestMessage(includeIcons: includeIcons)
        let message = try ControlMessage(type: .appListRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        MirageLogger.client("App list request sent")
    }

    /// Select an app to stream (streams all of its windows).
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier of the app to stream.
    ///   - quality: Quality preset for the streams.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///   - displayResolution: Client's display resolution for virtual display sizing.
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - keyframeQuality: Optional inter-frame quality (0.0-1.0).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    // TODO: HDR support - requires proper virtual display EDR configuration.
    // ///   - preferHDR: Whether to request HDR streaming (Rec. 2020 with PQ).
    func selectApp(
        bundleIdentifier: String,
        quality: MirageQualityPreset = .medium,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil
        // preferHDR: Bool = false
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        // Use provided display resolution or detect from main display.
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution ?? getMainDisplayResolution())

        var request = SelectAppMessage(
            bundleIdentifier: bundleIdentifier,
            preferredQuality: quality,
            dataPort: nil,
            scaleFactor: scaleFactor,
            displayWidth: effectiveDisplayResolution.width > 0 ? Int(effectiveDisplayResolution.width) : nil,
            displayHeight: effectiveDisplayResolution.height > 0 ? Int(effectiveDisplayResolution.height) : nil,
            maxRefreshRate: getScreenMaxRefreshRate(),
            keyFrameInterval: nil,
            frameQuality: nil,
            keyframeQuality: nil,
            pixelFormat: nil,
            colorSpace: nil,
            minBitrate: nil,
            maxBitrate: nil,
            streamScale: clampedStreamScale(),
            latencyMode: latencyMode
        )
        // TODO: HDR support - requires proper virtual display EDR configuration.
        // request.preferHDR = preferHDR

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        if overrides.frameQuality == nil { overrides.frameQuality = keyframeQuality }
        applyEncoderOverrides(overrides, to: &request)

        let message = try ControlMessage(type: .selectApp, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        streamingAppBundleID = bundleIdentifier
        MirageLogger.client("Requested to stream app: \(bundleIdentifier)")
    }

    /// Cancel a window cooldown and close immediately.
    /// - Parameter windowID: The window currently in cooldown.
    func cancelCooldown(windowID: WindowID) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let request = CancelCooldownMessage(windowID: windowID)
        let message = try ControlMessage(type: .cancelCooldown, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        MirageLogger.client("Cancel cooldown requested for window \(windowID)")
    }
}
