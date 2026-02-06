//
//  MirageHostService+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

// MARK: - Virtual Display Support

extension MirageHostService {
    private func virtualDisplayScaleFactor(for _: MirageConnectedClient?) -> CGFloat {
        // HiDPI virtual displays are always 2x logical points.
        // We intentionally ignore device-native scale to keep the host display
        // aligned with client view bounds.
        2.0
    }

    func virtualDisplayPixelResolution(
        for logicalResolution: CGSize,
        client: MirageConnectedClient?
    )
    -> CGSize {
        guard logicalResolution.width > 0, logicalResolution.height > 0 else { return logicalResolution }
        let scale = virtualDisplayScaleFactor(for: client)
        let width = CGFloat(StreamContext.alignedEvenPixel(logicalResolution.width * scale))
        let height = CGFloat(StreamContext.alignedEvenPixel(logicalResolution.height * scale))
        return CGSize(width: width, height: height)
    }

    func virtualDisplayLogicalResolution(
        for pixelResolution: CGSize,
        client: MirageConnectedClient?
    )
    -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else { return pixelResolution }
        let scale = virtualDisplayScaleFactor(for: client)
        return CGSize(
            width: pixelResolution.width / scale,
            height: pixelResolution.height / scale
        )
    }

    /// Send content bounds update to client
    func sendContentBoundsUpdate(streamID: StreamID, bounds: CGRect, to client: MirageConnectedClient) async {
        guard let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) else { return }

        let message = ContentBoundsUpdateMessage(streamID: streamID, bounds: bounds)
        do {
            try await clientContext.send(.contentBoundsUpdate, content: message)
            MirageLogger.host("Sent content bounds update for stream \(streamID): \(bounds)")
        } catch {
            MirageLogger.error(.host, "Failed to send content bounds update: \(error)")
        }
    }

    /// Handle detection of new independent window (auto-stream to client)
    func handleNewIndependentWindow(
        _ window: MirageWindow,
        originalStreamID: StreamID,
        client: MirageConnectedClient
    )
    async {
        MirageLogger.host("New independent window detected: \(window.id) '\(window.displayName)'")

        // Verify the original stream exists
        guard let originalContext = streamsByID[originalStreamID] else { return }

        // Get the virtual display resolution (client's display size)
        // Use SharedVirtualDisplayManager's getDisplayBounds which uses known resolution
        let displayResolution: CGSize = if let bounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
            bounds.size
        } else {
            // Fallback to window size if no virtual display
            window.frame.size
        }

        let streamScale = await originalContext.getStreamScale()
        let encoderSettings = await originalContext.getEncoderSettings()
        let targetFrameRate = await originalContext.getTargetFrameRate()

        // Auto-start a new stream for this window
        do {
            _ = try await startStream(
                for: window,
                to: client,
                dataPort: nil,
                clientDisplayResolution: displayResolution,
                keyFrameInterval: encoderSettings.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate,
                pixelFormat: encoderSettings.pixelFormat,
                colorSpace: encoderSettings.colorSpace,
                captureQueueDepth: encoderSettings.captureQueueDepth,
                bitrate: encoderSettings.bitrate
            )
            MirageLogger.host("Auto-started stream for new independent window \(window.id)")
        } catch {
            MirageLogger.error(.host, "Failed to auto-start stream for new window: \(error)")
        }
    }

    func handleStreamScaleChange(streamID: StreamID, streamScale: CGFloat) async {
        let clampedScale = max(0.1, min(1.0, streamScale))

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream scale change: \(streamID)")
            return
        }

        let currentScale = await context.getStreamScale()
        if abs(currentScale - clampedScale) <= 0.001 {
            MirageLogger.stream("Stream scale change skipped (already \(currentScale)) for stream \(streamID)")
            return
        }

        do {
            try await context.updateStreamScale(clampedScale)
            await sendStreamScaleUpdate(streamID: streamID)
        } catch {
            MirageLogger.error(.host, "Failed to update stream scale: \(error)")
        }
    }

    func handleStreamRefreshRateChange(
        streamID: StreamID,
        maxRefreshRate: Int,
        forceDisplayRefresh: Bool
    )
    async {
        let targetFrameRate = resolvedTargetFrameRate(maxRefreshRate)

        if streamID == desktopStreamID, let desktopContext = desktopStreamContext {
            let currentRate = await desktopContext.getTargetFrameRate()
            guard currentRate != targetFrameRate || forceDisplayRefresh else { return }

            do {
                try await desktopContext.updateFrameRate(targetFrameRate)
                if forceDisplayRefresh {
                    let encoded = await desktopContext.getEncodedDimensions()
                    let pixelResolution = CGSize(width: encoded.width, height: encoded.height)
                    let resolution = virtualDisplayLogicalResolution(
                        for: pixelResolution,
                        client: desktopStreamClientContext?.client
                    )
                    await handleDisplayResolutionChange(streamID: streamID, newResolution: resolution)
                }
                let appliedRate = await desktopContext.getTargetFrameRate()
                if appliedRate == targetFrameRate { MirageLogger.host("Desktop stream refresh override applied: \(targetFrameRate)fps") } else {
                    MirageLogger
                        .host(
                            "Desktop stream refresh override pending: requested \(targetFrameRate)fps, applied \(appliedRate)fps"
                        )
                }
            } catch {
                MirageLogger.error(.host, "Failed to update desktop stream refresh rate: \(error)")
            }
            return
        }

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for refresh rate change: \(streamID)")
            return
        }

        let currentRate = await context.getTargetFrameRate()
        guard currentRate != targetFrameRate || forceDisplayRefresh else { return }

        do {
            try await context.updateFrameRate(targetFrameRate)
            if forceDisplayRefresh, await context.isUsingVirtualDisplay() {
                let encoded = await context.getEncodedDimensions()
                let pixelResolution = CGSize(width: encoded.width, height: encoded.height)
                try await context.updateVirtualDisplayResolution(newResolution: pixelResolution)
                await sendStreamScaleUpdate(streamID: streamID)
            }
            let appliedRate = await context.getTargetFrameRate()
            if appliedRate == targetFrameRate { MirageLogger.host("Stream refresh override applied: \(targetFrameRate)fps") } else {
                MirageLogger
                    .host("Stream refresh override pending: requested \(targetFrameRate)fps, applied \(appliedRate)fps")
            }
        } catch {
            MirageLogger.error(.host, "Failed to update stream refresh rate: \(error)")
        }
    }

    func handleStreamEncoderSettingsChange(_ request: StreamEncoderSettingsChangeMessage) async {
        guard let context = streamsByID[request.streamID] else {
            MirageLogger.debug(.host, "No stream found for encoder settings update: \(request.streamID)")
            return
        }

        let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: request.bitrate)
        do {
            if request.pixelFormat != nil || request.colorSpace != nil || request.bitrate != nil {
                try await context.updateEncoderSettings(
                    pixelFormat: request.pixelFormat,
                    colorSpace: request.colorSpace,
                    bitrate: normalizedBitrate
                )
            }
            if let streamScale = request.streamScale {
                try await context.updateStreamScale(StreamContext.clampStreamScale(streamScale))
            }
            await sendStreamScaleUpdate(streamID: request.streamID)
        } catch {
            MirageLogger.error(.host, "Failed to apply encoder settings update: \(error)")
        }
    }

    func sendStreamScaleUpdate(streamID: StreamID) async {
        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream scale update: \(streamID)")
            return
        }

        let dimensionToken = await context.getDimensionToken()
        let encodedDimensions = await context.getEncodedDimensions()

        if streamID == desktopStreamID {
            if let clientContext = desktopStreamClientContext {
                let message = await DesktopStreamStartedMessage(
                    streamID: streamID,
                    width: encodedDimensions.width,
                    height: encodedDimensions.height,
                    frameRate: context.getTargetFrameRate(),
                    codec: context.getCodec(),
                    displayCount: 1,
                    dimensionToken: dimensionToken
                )
                try? await clientContext.send(.desktopStreamStarted, content: message)
            }

            if loginDisplayIsBorrowedStream, loginDisplayStreamID == streamID {
                loginDisplayResolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
                await broadcastLoginDisplayReady()
            }
            return
        }

        if streamID == loginDisplayStreamID {
            loginDisplayResolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
            await broadcastLoginDisplayReady()
            return
        }

        guard let session = activeStreams.first(where: { $0.id == streamID }) else { return }
        guard let clientContext = clientsByConnection.values.first(where: { $0.client.id == session.client.id }) else { return }

        let message = await StreamStartedMessage(
            streamID: streamID,
            windowID: session.window.id,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: context.getTargetFrameRate(),
            codec: context.getCodec(),
            minWidth: nil,
            minHeight: nil,
            dimensionToken: dimensionToken
        )
        try? await clientContext.send(.streamStarted, content: message)
    }

    /// Handle display resolution change from client
    func handleDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async {
        // Handle desktop stream resize differently from window streams
        // Desktop streaming needs to resize the entire virtual display and update capture
        if streamID == desktopStreamID, let desktopContext = desktopStreamContext {
            do {
                let logicalResolution = newResolution
                let pixelResolution = virtualDisplayPixelResolution(
                    for: logicalResolution,
                    client: desktopStreamClientContext?.client
                )
                let targetFrameRate = await desktopContext.getTargetFrameRate()
                let streamRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: targetFrameRate)

                if let snapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot() {
                    let currentResolution = snapshot.resolution
                    let currentRefresh = Int(snapshot.refreshRate.rounded())
                    if currentResolution == pixelResolution, currentRefresh == streamRefreshRate {
                        MirageLogger
                            .host(
                                "Desktop stream resize skipped (already " +
                                    "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                                    "\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px @\(streamRefreshRate)Hz)"
                            )
                        return
                    }
                }

                MirageLogger
                    .host(
                        "Desktop stream resize requested: " +
                            "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                            "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
                    )

                // 1. Update the virtual display resolution in place (no recreate, no displayID change)
                //    This uses applySettings: to change the display mode without destroying it
                try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                    for: .desktopStream,
                    newResolution: pixelResolution,
                    refreshRate: streamRefreshRate
                )

                // Re-apply mirroring after mode changes (display updates can drop mirror state).
                if let displayID = await SharedVirtualDisplayManager.shared.getDisplayID() {
                    if desktopStreamMode == .mirrored {
                        await setupDisplayMirroring(targetDisplayID: displayID)
                    } else if !mirroredPhysicalDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                        await disableDisplayMirroring(displayID: displayID)
                    }
                }

                // 2. Update the capture/encoder dimensions to match new resolution
                //    Since displayID doesn't change, we just need to update the stream config
                try await desktopContext.updateResolution(
                    width: Int(pixelResolution.width),
                    height: Int(pixelResolution.height)
                )

                // 3. Update input cache for mirrored content bounds on the physical display.
                let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
                let inputBounds = resolvedDesktopInputBounds(
                    physicalBounds: primaryBounds,
                    virtualResolution: pixelResolution
                )
                inputStreamCacheActor.updateWindowFrame(streamID, newFrame: inputBounds)
                MirageLogger
                    .host(
                        "Desktop stream resized to " +
                            "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                            "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px), input bounds: \(inputBounds)"
                    )

                // 4. Send desktopStreamStarted to notify client that resize is complete
                //    This triggers onStreamMinimumSizeUpdate which clears the resize blur
                if let clientContext = desktopStreamClientContext {
                    // Get updated dimension token after resize
                    let dimensionToken = await desktopStreamContext?.getDimensionToken() ?? 0

                    let encodedDimensions = await desktopStreamContext?.getEncodedDimensions() ?? (width: 0, height: 0)
                    let targetFrameRate = await desktopStreamContext?.getTargetFrameRate() ?? 120
                    let codec = await desktopStreamContext?.getCodec() ?? encoderConfig.codec
                    let message = DesktopStreamStartedMessage(
                        streamID: streamID,
                        width: encodedDimensions.0,
                        height: encodedDimensions.1,
                        frameRate: targetFrameRate,
                        codec: codec,
                        displayCount: 1,
                        dimensionToken: dimensionToken
                    )
                    try? await clientContext.send(.desktopStreamStarted, content: message)
                    MirageLogger.host("Sent desktop resize completion for stream \(streamID)")
                }
            } catch {
                MirageLogger.error(.host, "Failed to resize desktop stream: \(error)")
            }
            return
        }

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for display resolution change: \(streamID)")
            return
        }

        do {
            let client = activeStreams.first(where: { $0.id == streamID })?.client
            let logicalResolution = newResolution
            let pixelResolution = virtualDisplayPixelResolution(
                for: logicalResolution,
                client: client
            )
            try await context.updateVirtualDisplayResolution(newResolution: pixelResolution)

            // Update the cached shared display bounds after resolution change
            // Use SharedVirtualDisplayManager's getDisplayBounds which uses known resolution
            if let newBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
                sharedVirtualDisplayBounds = newBounds
                MirageLogger.host("Updated shared virtual display bounds to: \(newBounds)")

                // Also update input cache with new bounds for correct mouse coordinate translation
                let windowID = context.getWindowID()
                if let newFrame = currentWindowFrame(for: windowID) { inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame) }
            }

            MirageLogger
                .host(
                    "Updated virtual display resolution for stream \(streamID) to " +
                        "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                        "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
                )
        } catch {
            MirageLogger.error(.host, "Failed to update virtual display resolution: \(error)")
        }
    }
}

#endif
