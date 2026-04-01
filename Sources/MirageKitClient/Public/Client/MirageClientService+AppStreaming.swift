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
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

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
        try await sendControlMessage(.appListRequest, content: request)
        // App-list snapshots and follow-up icon diffs can temporarily monopolize
        // the control channel. Give the heartbeat room so it does not declare a
        // false disconnect while the host is still servicing metadata work.
        heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
        activeAppListRequestID = requestID
        appIconStreamStateByRequestID.removeAll(keepingCapacity: false)
        appIconStreamStateByRequestID[requestID] = AppIconStreamState()
        pendingForceIconResetForNextAppListRequest = false
        MirageLogger.client("App list request sent")
    }

    /// Request the connected host's hardware icon payload.
    /// - Parameter preferredMaxPixelSize: Preferred max pixel size for the returned PNG.
    func requestHostHardwareIcon(preferredMaxPixelSize: Int = 512) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let request = HostHardwareIconRequestMessage(preferredMaxPixelSize: preferredMaxPixelSize)
        try await sendControlMessage(.hostHardwareIconRequest, content: request)
        // Hardware-icon payloads are large enough to compete with heartbeat pings.
        // Keep the connection in a grace window until the host finishes responding.
        heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
        MirageLogger.client("Host hardware icon request sent")
    }

    /// Request the connected host's wallpaper payload.
    /// - Parameters:
    ///   - preferredMaxPixelWidth: Preferred maximum wallpaper width in pixels.
    ///   - preferredMaxPixelHeight: Preferred maximum wallpaper height in pixels.
    func requestHostWallpaper(
        preferredMaxPixelWidth: Int = 1_280,
        preferredMaxPixelHeight: Int = 720
    ) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard hostWallpaperContinuation == nil else {
            throw MirageError.protocolError("Host wallpaper request already in progress")
        }

        let requestID = UUID()
        let request = HostWallpaperRequestMessage(
            requestID: requestID,
            preferredMaxPixelWidth: preferredMaxPixelWidth,
            preferredMaxPixelHeight: preferredMaxPixelHeight
        )
        heartbeatGraceDeadline = ContinuousClock.now + hostWallpaperTimeout

        try await withCheckedThrowingContinuation { continuation in
            hostWallpaperRequestID = requestID
            hostWallpaperContinuation = continuation
            hostWallpaperTransferTask?.cancel()
            hostWallpaperTransferTask = nil
            hostWallpaperTimeoutTask?.cancel()
            hostWallpaperTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.hostWallpaperTimeout ?? .seconds(45))
                guard let self,
                      self.hostWallpaperContinuation != nil else {
                    return
                }
                completeHostWallpaperRequest(
                    .failure(MirageError.protocolError("Timed out waiting for host wallpaper"))
                )
            }
            Task { @MainActor [weak self] in
                do {
                    try await self?.sendControlMessage(.hostWallpaperRequest, content: request)
                    MirageLogger.client(
                        "Host wallpaper request sent requestID=\(requestID.uuidString.lowercased()) target=\(preferredMaxPixelWidth)x\(preferredMaxPixelHeight)"
                    )
                } catch {
                    self?.completeHostWallpaperRequest(.failure(error))
                }
            }
        }
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
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy = .prioritizeActiveWindow,
        sizePreset: MirageDisplaySizePreset? = nil
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        guard let displayResolution else {
            throw MirageError.protocolError("Display size unavailable for app streaming")
        }
        let effectiveDisplayResolution = scaledDisplayResolution(displayResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for app streaming")
        }
        var encoderRequest = SelectAppMessage(
            bundleIdentifier: bundleIdentifier,
            dataPort: nil,
            scaleFactor: nil,
            displayWidth: effectiveDisplayResolution.width > 0 ? Int(effectiveDisplayResolution.width) : nil,
            displayHeight: effectiveDisplayResolution.height > 0 ? Int(effectiveDisplayResolution.height) : nil,
            maxRefreshRate: getScreenMaxRefreshRate(),
            keyFrameInterval: nil,
            colorDepth: nil,
            bitrate: nil,
            streamScale: nil,
            audioConfiguration: audioConfiguration ?? self.audioConfiguration,
            maxConcurrentVisibleWindows: max(1, maxConcurrentVisibleWindows),
            bitrateAllocationPolicy: bitrateAllocationPolicy,
            sizePreset: sizePreset,
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
        var request = SelectAppMessage(
            bundleIdentifier: encoderRequest.bundleIdentifier,
            dataPort: encoderRequest.dataPort,
            scaleFactor: geometry.displayScaleFactor,
            displayWidth: encoderRequest.displayWidth,
            displayHeight: encoderRequest.displayHeight,
            maxRefreshRate: encoderRequest.maxRefreshRate,
            keyFrameInterval: encoderRequest.keyFrameInterval,
            captureQueueDepth: encoderRequest.captureQueueDepth,
            colorDepth: encoderRequest.colorDepth,
            bitrate: scaledBitrate,
            latencyMode: encoderRequest.latencyMode,
            performanceMode: encoderRequest.performanceMode,
            allowRuntimeQualityAdjustment: encoderRequest.allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: encoderRequest.lowLatencyHighResolutionCompressionBoost,
            temporaryDegradationMode: encoderRequest.temporaryDegradationMode,
            disableResolutionCap: encoderRequest.disableResolutionCap,
            streamScale: geometry.resolvedStreamScale,
            audioConfiguration: encoderRequest.audioConfiguration,
            maxConcurrentVisibleWindows: encoderRequest.maxConcurrentVisibleWindows,
            bitrateAllocationPolicy: encoderRequest.bitrateAllocationPolicy,
            sizePreset: encoderRequest.sizePreset,
            mediaMaxPacketSize: encoderRequest.mediaMaxPacketSize
        )
        request.bitrateAdaptationCeiling = encoderRequest.bitrateAdaptationCeiling
        request.encoderMaxWidth = encoderRequest.encoderMaxWidth
        request.encoderMaxHeight = encoderRequest.encoderMaxHeight
        request.upscalingMode = encoderRequest.upscalingMode
        request.codec = encoderRequest.codec
        pendingAppAdaptiveFallbackBitrate = request.bitrate
        pendingAppAdaptiveFallbackColorDepth = request.colorDepth

        try await sendControlMessage(.selectApp, content: request)

        // Allow time for the host to process the selectApp and start the
        // stream before heartbeat pings fire.  Without this, the heavy
        // icon-update traffic on the control channel can delay pong
        // responses past the 1-second timeout, causing a false disconnect.
        heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)

        streamingAppBundleID = bundleIdentifier
        MirageLogger.client(
            "Requested to stream app: \(bundleIdentifier) at " +
                "\(Int(geometry.logicalSize.width))x\(Int(geometry.logicalSize.height)) pts, " +
                "\(Int(geometry.displayPixelSize.width))x\(Int(geometry.displayPixelSize.height)) px, " +
                "encode \(Int(geometry.encodedPixelSize.width))x\(Int(geometry.encodedPixelSize.height)) px"
        )
    }

    /// Request a host-side slot swap from hidden inventory into a visible stream slot.
    func requestAppWindowSwap(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID
    ) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        let request = AppWindowSwapRequestMessage(
            bundleIdentifier: bundleIdentifier,
            targetSlotStreamID: targetSlotStreamID,
            targetWindowID: targetWindowID
        )
        try await sendControlMessage(.appWindowSwapRequest, content: request)
    }

    /// Request execution of an actionable host close-blocking alert button.
    func requestAppWindowCloseAlertAction(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID
    ) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        let request = AppWindowCloseAlertActionRequestMessage(
            alertToken: alertToken,
            actionID: actionID,
            presentingStreamID: presentingStreamID
        )
        try await sendControlMessage(.appWindowCloseAlertActionRequest, content: request)
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
