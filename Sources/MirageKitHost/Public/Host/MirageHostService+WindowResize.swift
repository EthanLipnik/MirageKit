//
//  MirageHostService+WindowResize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    /// Coalesces client-requested app/window resize updates per stream.
    private func enqueueWindowResolutionChange(streamID: StreamID, logicalResolution: CGSize) async {
        pendingWindowResizeResolutionByStreamID[streamID] = logicalResolution
        let nextRequestNumber = (windowResizeRequestCounterByStreamID[streamID] ?? 0) + 1
        windowResizeRequestCounterByStreamID[streamID] = nextRequestNumber
        MirageLogger
            .host(
                "Queued app/window resize request #\(nextRequestNumber) for stream \(streamID): " +
                    "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts"
            )

        guard !windowResizeInFlightStreamIDs.contains(streamID) else { return }
        windowResizeInFlightStreamIDs.insert(streamID)
        defer { windowResizeInFlightStreamIDs.remove(streamID) }

        while let pendingResolution = pendingWindowResizeResolutionByStreamID[streamID] {
            pendingWindowResizeResolutionByStreamID[streamID] = nil
            let latestRequestNumber = windowResizeRequestCounterByStreamID[streamID] ?? nextRequestNumber
            await applyWindowResolutionChange(
                streamID: streamID,
                logicalResolution: pendingResolution,
                requestNumber: latestRequestNumber
            )

            guard streamsByID[streamID] != nil else {
                pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
                windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
                stopWindowVisibleFrameMonitor(streamID: streamID)
                return
            }
        }
    }

    /// Applies one logical resize request to a virtual-display-backed window stream.
    private func applyWindowResolutionChange(
        streamID: StreamID,
        logicalResolution: CGSize,
        requestNumber: UInt64
    )
    async {
        guard let context = streamsByID[streamID] else { return }
        guard let session = activeSessionByStreamID[streamID] else { return }
        let clientScaleOverride = clientVirtualDisplayScaleFactor(streamID: streamID)
        let pixelResolution = virtualDisplayPixelResolution(
            for: logicalResolution,
            scaleFactorOverride: clientScaleOverride
        )
        let currentState = virtualDisplayState(streamID: streamID)
        let currentVisibleResolution = currentState?.visiblePixelResolution
        let currentDisplayResolution = currentState?.pixelResolution
        let currentEncodedDimensions = await context.encodedDimensions
        let currentEncodedResolution = CGSize(
            width: CGFloat(currentEncodedDimensions.width),
            height: CGFloat(currentEncodedDimensions.height)
        )
        let currentEncoderMaxDimensions = await context.encoderMaxDimensions
        let requestedEncodedResolution = await MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: pixelResolution,
            requestedStreamScale: context.requestedStreamScale,
            encoderMaxWidth: currentEncoderMaxDimensions.width ?? Int(StreamContext.maxEncodedWidth),
            encoderMaxHeight: currentEncoderMaxDimensions.height ?? Int(StreamContext.maxEncodedHeight),
            disableResolutionCap: context.disableResolutionCap
        ).encodedPixelSize
        let requestedAspectRatio = resolvedAppStreamResizeAspectRatio(
            existingAspectRatio: currentState?.targetContentAspectRatio,
            requestedLogicalResolution: logicalResolution
        )
        let placementNoOpDecision = windowResizePlacementNoOpDecision(
            currentBounds: currentState?.bounds,
            displayVisibleBounds: currentState?.displayVisibleBounds,
            requestedAspectRatio: requestedAspectRatio
        )
        let resolutionNoOpDecision = windowResizeNoOpDecision(
            currentVisibleResolution: currentVisibleResolution,
            currentDisplayResolution: currentDisplayResolution,
            currentEncodedResolution: currentEncodedResolution,
            requestedVisibleResolution: pixelResolution,
            requestedEncodedResolution: requestedEncodedResolution
        )
        if windowResizeCombinedNoOpDecision(
            placementDecision: placementNoOpDecision,
            resolutionDecision: resolutionNoOpDecision
        ) == .noOp {
            await sendWindowResizeCompletion(
                streamID: streamID,
                requestNumber: requestNumber,
                context: context,
                noOp: true
            )
            return
        }

        do {
            try await context.updateWindowCaptureResolution(
                newLogicalSize: logicalResolution,
                targetAspectRatioOverride: requestedAspectRatio,
                forceReconfigure: false
            )
            await refreshWindowVirtualDisplayState(
                streamID: streamID,
                context: context,
                clientScaleFactorOverride: clientScaleOverride,
                targetContentAspectRatioOverride: requestedAspectRatio
            )
            if let appSession = await appStreamManager.sessionForStreamID(streamID) {
                await appStreamManager.setCapturedClusterWindowIDs(
                    bundleIdentifier: appSession.bundleIdentifier,
                    streamID: streamID,
                    capturedClusterWindowIDs: context.capturedWindowClusterWindowIDs
                )
            }
            await sendWindowResizeCompletion(
                streamID: streamID,
                requestNumber: requestNumber,
                context: context,
                noOp: false
            )
            ensureWindowVisibleFrameMonitor(streamID: streamID)
            MirageLogger
                .host(
                    "Applied app/window resize request #\(requestNumber) for stream \(streamID): " +
                        "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                        "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
                )
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to apply app/window resize request #\(requestNumber) for stream \(streamID): "
            )
            if let clientContext = findClientContext(clientID: session.client.id) {
                let errorMessage = ErrorMessage(
                    code: .virtualDisplayResizeFailed,
                    message: "Failed to update dedicated display for stream \(streamID): \(error.localizedDescription)"
                )
                do {
                    try await clientContext.send(.error, content: errorMessage)
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to send resize error response: ")
                }
            }
            // Window resize is lightweight — keep the stream alive with last-known state.
            await refreshWindowVirtualDisplayState(
                streamID: streamID,
                context: context,
                clientScaleFactorOverride: clientScaleOverride
            )
            await sendWindowResizeCompletion(
                streamID: streamID,
                requestNumber: requestNumber,
                context: context,
                noOp: true
            )
            ensureWindowVisibleFrameMonitor(streamID: streamID)
        }
    }

    /// Sends updated stream metadata after an app/window resize completes.
    private func sendWindowResizeCompletion(
        streamID: StreamID,
        requestNumber: UInt64,
        context: StreamContext,
        noOp: Bool
    )
    async {
        guard let currentSession = activeSessionByStreamID[streamID] else { return }
        guard let clientContext = findClientContext(clientID: currentSession.client.id) else { return }

        let resolvedWindowFrame = virtualDisplayBounds(windowID: currentSession.window.id)
            ?? currentWindowFrame(for: currentSession.window.id)
            ?? currentSession.window.frame
        let updatedWindow = MirageWindow(
            id: currentSession.window.id,
            title: currentSession.window.title,
            application: currentSession.window.application,
            frame: resolvedWindowFrame,
            isOnScreen: currentSession.window.isOnScreen,
            windowLayer: currentSession.window.windowLayer
        )
        registerActiveStreamSession(
            MirageStreamSession(
                id: currentSession.id,
                window: updatedWindow,
                client: currentSession.client
            )
        )
        inputStreamCache.updateWindowFrame(streamID, newFrame: updatedWindow.frame)

        let minSize = await resolvedMinimumSize(for: updatedWindow)
        let minWidth = Int(minSize.width)
        let minHeight = Int(minSize.height)
        let streamStart = await context.streamStartSnapshot
        let message = StreamStartedMessage(
            streamID: streamID,
            windowID: updatedWindow.id,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            minWidth: minWidth,
            minHeight: minHeight,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
        )
        do {
            try await clientContext.send(.streamStarted, content: message)
            let suffix = noOp ? ", no-op" : ""
            MirageLogger.host(
                "Sent app/window resize completion for stream \(streamID) (request #\(requestNumber)\(suffix))"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send app/window resize completion: ")
        }
    }

    /// Routes a client-requested logical resolution change to the correct stream type.
    func handleDisplayResolutionChange(
        streamID: StreamID,
        newResolution: CGSize,
        transitionID: UUID? = nil,
        requestedDisplayScaleFactor: CGFloat? = nil,
        requestedStreamScale: CGFloat? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil
    )
    async {
        if streamID == desktopStreamID {
            if desktopUsesHostResolution {
                MirageLogger.host(
                    "Ignoring display resolution change for host-resolution desktop stream \(streamID): " +
                        "\(Int(newResolution.width))x\(Int(newResolution.height)) pts"
                )
                return
            }
            await enqueueDesktopResolutionChange(
                streamID: streamID,
                request: DesktopResizeRequestState(
                    logicalResolution: newResolution,
                    transitionID: transitionID ?? UUID(),
                    requestedDisplayScaleFactor: requestedDisplayScaleFactor,
                    requestedStreamScale: requestedStreamScale,
                    encoderMaxWidth: encoderMaxWidth,
                    encoderMaxHeight: encoderMaxHeight
                )
            )
            return
        }

        if let appSession = await appStreamManager.sessionForStreamID(streamID),
           let isActive = await appStreamManager.streamActivity(
               bundleIdentifier: appSession.bundleIdentifier,
               streamID: streamID
           ),
           !isActive {
            MirageLogger
                .debug(
                    .host,
                    "Ignoring display resolution change for passive app stream \(streamID)"
                )
            return
        }

        if streamsByID[streamID] == nil,
           let appSession = await appStreamManager.sessionForStreamID(streamID) {
            await applyAppAtlasLogicalWindowResize(
                streamID: streamID,
                newResolution: newResolution,
                appSession: appSession
            )
            return
        }

        guard streamsByID[streamID] != nil else {
            MirageLogger.debug(.host, "No stream found for display resolution change: \(streamID)")
            return
        }
        await enqueueWindowResolutionChange(streamID: streamID, logicalResolution: newResolution)
    }

    /// Applies a logical resize to an app-atlas stream that does not own a live `StreamContext`.
    private func applyAppAtlasLogicalWindowResize(
        streamID: StreamID,
        newResolution: CGSize,
        appSession: MirageAppStreamSession
    ) async {
        guard let session = activeSessionByStreamID[streamID] else { return }
        let targetSize = CGSize(
            width: max(1, newResolution.width),
            height: max(1, newResolution.height)
        )
        let resized = await WindowSpaceManager.shared.resizeWindow(session.window.id, to: targetSize)
        guard resized else {
            MirageLogger.host(
                "App-atlas logical resize did not apply for stream \(streamID): " +
                    "\(Int(targetSize.width))x\(Int(targetSize.height)) pts"
            )
            return
        }

        let latestFrame = currentWindowFrame(for: session.window.id) ?? CGRect(
            origin: session.window.frame.origin,
            size: targetSize
        )
        let updatedWindow = MirageWindow(
            id: session.window.id,
            title: session.window.title,
            application: session.window.application,
            frame: latestFrame,
            isOnScreen: session.window.isOnScreen,
            windowLayer: session.window.windowLayer
        )
        registerActiveStreamSession(
            MirageStreamSession(
                id: streamID,
                window: updatedWindow,
                client: session.client
            )
        )
        inputStreamCache.updateWindowFrame(streamID, newFrame: updatedWindow.frame)

        if let windowInfo = appSession.windowStreams[updatedWindow.id] {
            await appStreamManager.replaceVisibleWindowForStream(
                bundleIdentifier: appSession.bundleIdentifier,
                streamID: streamID,
                newWindowID: updatedWindow.id,
                title: updatedWindow.title,
                width: Int(max(1, latestFrame.width.rounded())),
                height: Int(max(1, latestFrame.height.rounded())),
                isResizable: windowInfo.isResizable,
                capturedClusterWindowIDs: [],
                mediaStreamID: windowInfo.mediaStreamID,
                atlasRegion: windowInfo.atlasRegion
            )
        }
        await sendAppWindowInventoryUpdate(
            bundleIdentifier: appSession.bundleIdentifier,
            clientID: appSession.clientID
        )
        MirageLogger.host(
            "Applied app-atlas logical resize for stream \(streamID): " +
                "\(Int(targetSize.width))x\(Int(targetSize.height)) pts"
        )
    }
}

#endif
