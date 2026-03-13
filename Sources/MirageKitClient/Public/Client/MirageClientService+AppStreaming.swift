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
import MirageKit

@MainActor
public extension MirageClientService {
    /// Request list of installed apps from host.
    /// - Parameter forceRefresh: Whether host-side app-list caches should be bypassed.
    /// - Parameter forceIconReset: Whether host-side icon-diff caches should be bypassed.
    /// - Parameter priorityBundleIdentifiers: Client-preferred icon streaming order.
    func requestAppList(
        forceRefresh: Bool = false,
        forceIconReset: Bool = false,
        priorityBundleIdentifiers: [String] = []
    ) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let shouldForceIconReset = forceIconReset || pendingForceIconResetForNextAppListRequest
        let normalizedPriority = Self.normalizedPriorityBundleIdentifiers(priorityBundleIdentifiers)
        let requestID = UUID()
        MirageLogger.client(
            "Requesting app list from host (forceRefresh: \(forceRefresh), forceIconReset: \(shouldForceIconReset), priorityCount: \(normalizedPriority.count), requestID: \(requestID.uuidString))"
        )
        let request = AppListRequestMessage(
            forceRefresh: forceRefresh,
            forceIconReset: shouldForceIconReset,
            priorityBundleIdentifiers: normalizedPriority,
            requestID: requestID
        )
        let message = try ControlMessage(type: .appListRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        activeAppListRequestID = requestID
        appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
        appIconStreamStateByRequestID[requestID] = AppIconStreamState()
        pendingForceIconResetForNextAppListRequest = false
        MirageLogger.client("App list request sent")
    }

    /// Request the connected host's hardware icon payload.
    /// - Parameter preferredMaxPixelSize: Preferred max pixel size for the returned PNG.
    func requestHostHardwareIcon(preferredMaxPixelSize: Int = 512) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        let request = HostHardwareIconRequestMessage(preferredMaxPixelSize: preferredMaxPixelSize)
        let message = try ControlMessage(type: .hostHardwareIconRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
        MirageLogger.client("Host hardware icon request sent")
    }

    /// Select an app to stream.
    /// - Parameters:
    ///   - bundleIdentifier: Bundle identifier of the app to stream.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///   - displayResolution: Client's logical display size in points for virtual display sizing.
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    ///   - maxConcurrentVisibleWindows: Maximum visible app-window slots allowed for this session.
    ///   - bitrateAllocationPolicy: Shared app-stream bitrate allocation mode.
    func selectApp(
        bundleIdentifier: String,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        maxConcurrentVisibleWindows: Int = 1,
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy = .prioritizeActiveWindow
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }

        guard let displayResolution else {
            throw MirageError.protocolError("Display size unavailable for app streaming")
        }
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for app streaming")
        }
        let resolvedScaleFactor = resolvedDisplayScaleFactor(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor
        )

        var request = SelectAppMessage(
            bundleIdentifier: bundleIdentifier,
            dataPort: nil,
            scaleFactor: resolvedScaleFactor,
            displayWidth: effectiveDisplayResolution.width > 0 ? Int(effectiveDisplayResolution.width) : nil,
            displayHeight: effectiveDisplayResolution.height > 0 ? Int(effectiveDisplayResolution.height) : nil,
            maxRefreshRate: getScreenMaxRefreshRate(),
            keyFrameInterval: nil,
            colorDepth: nil,
            bitrate: nil,
            streamScale: clampedStreamScale(),
            audioConfiguration: audioConfiguration ?? self.audioConfiguration,
            maxConcurrentVisibleWindows: max(1, maxConcurrentVisibleWindows),
            bitrateAllocationPolicy: bitrateAllocationPolicy
        )

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &request)
        if let bitrate = request.bitrate, bitrate > 0 {
            pendingAppAdaptiveFallbackBitrate = bitrate
        } else {
            pendingAppAdaptiveFallbackBitrate = nil
        }
        pendingAppAdaptiveFallbackColorDepth = request.colorDepth

        let message = try ControlMessage(type: .selectApp, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)

        streamingAppBundleID = bundleIdentifier
        MirageLogger.client("Requested to stream app: \(bundleIdentifier)")
    }

    /// Request a host-side slot swap from hidden inventory into a visible stream slot.
    func requestAppWindowSwap(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID
    ) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }
        let request = AppWindowSwapRequestMessage(
            bundleIdentifier: bundleIdentifier,
            targetSlotStreamID: targetSlotStreamID,
            targetWindowID: targetWindowID
        )
        let message = try ControlMessage(type: .appWindowSwapRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    /// Request execution of an actionable host close-blocking alert button.
    func requestAppWindowCloseAlertAction(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID
    ) async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }
        let request = AppWindowCloseAlertActionRequestMessage(
            alertToken: alertToken,
            actionID: actionID,
            presentingStreamID: presentingStreamID
        )
        let message = try ControlMessage(type: .appWindowCloseAlertActionRequest, content: request)
        connection.send(content: message.serialize(), completion: .idempotent)
    }

    /// Clears cached icon payloads for the current in-memory app list snapshot.
    func invalidateAvailableAppIcons() {
        availableApps = availableApps.map { app in
            MirageInstalledApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                path: app.path,
                iconData: nil,
                version: app.version,
                isRunning: app.isRunning,
                isBeingStreamed: app.isBeingStreamed
            )
        }
    }

    private static func normalizedPriorityBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(bundleIdentifiers.count)

        for bundleIdentifier in bundleIdentifiers {
            let normalized = bundleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

}
