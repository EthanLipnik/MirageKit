import Foundation
import CoreGraphics

#if os(macOS)

// MARK: - Virtual Display Support

extension MirageHostService {
    /// Send content bounds update to client
    func sendContentBoundsUpdate(streamID: StreamID, bounds: CGRect, to client: MirageConnectedClient) async {
        guard let clientContext = clientsByConnection.values.first(where: { $0.client.id == client.id }) else {
            return
        }

        let message = ContentBoundsUpdateMessage(streamID: streamID, bounds: bounds)
        do {
            try await clientContext.send(.contentBoundsUpdate, content: message)
            MirageLogger.host("Sent content bounds update for stream \(streamID): \(bounds)")
        } catch {
            MirageLogger.error(.host, "Failed to send content bounds update: \(error)")
        }
    }

    /// Handle detection of new independent window (auto-stream to client)
    func handleNewIndependentWindow(_ window: MirageWindow, originalStreamID: StreamID, client: MirageConnectedClient) async {
        MirageLogger.host("New independent window detected: \(window.id) '\(window.displayName)'")

        // Verify the original stream exists
        guard let originalContext = streamsByID[originalStreamID] else { return }

        // Get the virtual display resolution (client's display size)
        // Use SharedVirtualDisplayManager's getDisplayBounds which uses known resolution
        let displayResolution: CGSize
        if let bounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
            displayResolution = bounds.size
        } else {
            // Fallback to window size if no virtual display
            displayResolution = window.frame.size
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
                maxBitrate: encoderSettings.maxBitrate,
                keyFrameInterval: encoderSettings.keyFrameInterval,
                keyframeQuality: encoderSettings.keyframeQuality,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate
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

        do {
            try await context.updateStreamScale(clampedScale)
            let dimensionToken = await context.getDimensionToken()
            let encodedDimensions = await context.getEncodedDimensions()

            if streamID == desktopStreamID {
                if let clientContext = desktopStreamClientContext {
                    let message = DesktopStreamStartedMessage(
                        streamID: streamID,
                        width: encodedDimensions.width,
                        height: encodedDimensions.height,
                        frameRate: await context.getTargetFrameRate(),
                        codec: await context.getCodec(),
                        displayCount: 1,
                        dimensionToken: dimensionToken
                    )
                    try? await clientContext.send(.desktopStreamStarted, content: message)
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

            let message = StreamStartedMessage(
                streamID: streamID,
                windowID: session.window.id,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: await context.getTargetFrameRate(),
                codec: await context.getCodec(),
                minWidth: nil,
                minHeight: nil,
                dimensionToken: dimensionToken
            )
            try? await clientContext.send(.streamStarted, content: message)
        } catch {
            MirageLogger.error(.host, "Failed to update stream scale: \(error)")
        }
    }

    /// Handle display resolution change from client
    func handleDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async {
        // Handle desktop stream resize differently from window streams
        // Desktop streaming needs to resize the entire virtual display and update capture
        if streamID == desktopStreamID, let desktopContext = desktopStreamContext {
            do {
                MirageLogger.host("Desktop stream resize requested: \(Int(newResolution.width))x\(Int(newResolution.height))")

                // 1. Update the virtual display resolution in place (no recreate, no displayID change)
                //    This uses applySettings: to change the display mode without destroying it
                let targetFrameRate = await desktopContext.getTargetFrameRate()
                try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                    for: .desktopStream,
                    newResolution: newResolution,
                    refreshRate: targetFrameRate
                )

                // 2. Update the capture/encoder dimensions to match new resolution
                //    Since displayID doesn't change, we just need to update the stream config
                try await desktopContext.updateResolution(
                    width: Int(newResolution.width),
                    height: Int(newResolution.height)
                )

                // 3. Update input cache with main display bounds (since main mirrors virtual)
                // Input is injected at main display coordinates, not virtual display coordinates
                let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
                inputStreamCacheActor.updateWindowFrame(streamID, newFrame: mainDisplayBounds)
                MirageLogger.host("Desktop stream resized to \(Int(newResolution.width))x\(Int(newResolution.height)), input bounds: \(mainDisplayBounds)")

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
            try await context.updateVirtualDisplayResolution(newResolution: newResolution)

            // Update the cached shared display bounds after resolution change
            // Use SharedVirtualDisplayManager's getDisplayBounds which uses known resolution
            if let newBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
                sharedVirtualDisplayBounds = newBounds
                MirageLogger.host("Updated shared virtual display bounds to: \(newBounds)")

                // Also update input cache with new bounds for correct mouse coordinate translation
                let windowID = context.getWindowID()
                if let newFrame = currentWindowFrame(for: windowID) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                }
            }

            MirageLogger.host("Updated virtual display resolution for stream \(streamID) to \(Int(newResolution.width))x\(Int(newResolution.height))")
        } catch {
            MirageLogger.error(.host, "Failed to update virtual display resolution: \(error)")
        }
    }
}

#endif
