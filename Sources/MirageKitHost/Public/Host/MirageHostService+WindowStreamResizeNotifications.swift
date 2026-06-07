//
//  MirageHostService+WindowStreamResizeNotifications.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Refreshes host-side stream state after a streamed window changes size.
    func notifyWindowResized(_ window: MirageMedia.MirageWindow) async {
        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageMedia.MirageWindow(
            id: window.id,
            title: window.title,
            application: window.application,
            frame: latestFrame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )

        guard let streamID = activeStreamIDByWindowID[window.id],
              let session = activeSessionByStreamID[streamID],
              let context = streamsByID[streamID] else {
            return
        }

        if isStreamUsingVirtualDisplay(windowID: window.id) {
            if let bounds = virtualDisplayBounds(windowID: window.id) {
                inputStreamCache.updateWindowFrame(session.id, newFrame: bounds)
            }
            _ = await enforceVirtualDisplayPlacementAfterActivation(windowID: window.id)
            return
        }

        registerActiveStreamSession(
            MirageStreamSession(
                id: session.id,
                window: updatedWindow,
                client: session.client
            )
        )

        inputStreamCache.updateWindowFrame(session.id, newFrame: latestFrame)

        do {
            try await context.updateDimensions(windowFrame: updatedWindow.frame)

            let streamStart = await context.streamStartSnapshot

            if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = await resolvedMinimumSize(for: updatedWindow)
                let minWidth = Int(minSize.width)
                let minHeight = Int(minSize.height)

                let message = MirageWire.StreamStartedMessage(
                    streamID: session.id,
                    windowID: window.id,
                    width: streamStart.encodedDimensions.width,
                    height: streamStart.encodedDimensions.height,
                    frameRate: streamStart.targetFrameRate,
                    codec: streamStart.codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: streamStart.dimensionToken,
                    acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger
                    .host("Encoding at scaled resolution: \(streamStart.encodedDimensions.width)x\(streamStart.encodedDimensions.height)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update stream dimensions: ")
        }
    }

    /// Applies a client-requested capture resolution to an active window stream.
    func updateCaptureResolution(for windowID: WindowID, width: Int, height: Int) async {
        guard let streamID = activeStreamIDByWindowID[windowID],
              let session = activeSessionByStreamID[streamID],
              let context = streamsByID[streamID] else {
            MirageLogger.host("No active stream found for window \(windowID)")
            return
        }
        if isStreamUsingVirtualDisplay(windowID: windowID) {
            MirageLogger.host(
                "Ignoring capture-resolution resize for window \(windowID) using dedicated virtual display"
            )
            return
        }

        let latestFrame = currentWindowFrame(for: windowID) ?? session.window.frame

        let updatedWindow = MirageMedia.MirageWindow(
            id: session.window.id,
            title: session.window.title,
            application: session.window.application,
            frame: latestFrame,
            isOnScreen: session.window.isOnScreen,
            windowLayer: session.window.windowLayer
        )
        registerActiveStreamSession(
            MirageStreamSession(
                id: session.id,
                window: updatedWindow,
                client: session.client
            )
        )

        do {
            try await context.updateResolution(width: width, height: height)

            let streamStart = await context.streamStartSnapshot

            if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = await resolvedMinimumSize(for: updatedWindow)
                let minWidth = Int(minSize.width)
                let minHeight = Int(minSize.height)

                let message = MirageWire.StreamStartedMessage(
                    streamID: session.id,
                    windowID: windowID,
                    width: width,
                    height: height,
                    frameRate: streamStart.targetFrameRate,
                    codec: streamStart.codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: streamStart.dimensionToken,
                    acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger.host("Capture resolution updated to \(width)x\(height)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update capture resolution: ")
        }
    }
}
#endif
