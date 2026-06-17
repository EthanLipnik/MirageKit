//
//  MirageHostService+StreamSettings.swift
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
    /// Applies a client-requested stream scale change.
    func handleStreamScaleChange(streamID: StreamID, streamScale: CGFloat) async {
        let clampedScale = max(0.1, min(1.0, streamScale))

        if streamID == desktopStreamID, desktopUsesHostResolution {
            MirageLogger.host(
                "Ignoring stream scale change for host-resolution desktop stream \(streamID): \(clampedScale)"
            )
            return
        }

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream scale change: \(streamID)")
            return
        }

        let currentScale = await context.streamScale
        if abs(currentScale - clampedScale) <= 0.001 {
            MirageLogger.stream("Stream scale change skipped (already \(currentScale)) for stream \(streamID)")
            return
        }

        do {
            try await context.updateStreamScale(clampedScale)
            await sendStreamScaleUpdate(streamID: streamID)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update stream scale: ")
        }
    }

    /// Applies a client-requested stream refresh-rate change.
    func handleStreamRefreshRateChange(
        streamID: StreamID,
        maxRefreshRate: Int,
        forceDisplayRefresh: Bool
    )
    async {
        let targetFrameRate = resolvedTargetFrameRate(maxRefreshRate)

        if streamID == desktopStreamID, let desktopContext = desktopStreamContext {
            let currentRate = await desktopContext.encoderConfig.targetFrameRate
            guard currentRate != targetFrameRate || forceDisplayRefresh else { return }

            do {
                try await desktopContext.updateFrameRate(targetFrameRate)
                if forceDisplayRefresh {
                    MirageLogger.host(
                        "Desktop stream force refresh applied without deriving display geometry from encoded dimensions"
                    )
                }
                let appliedRate = await desktopContext.encoderConfig.targetFrameRate
                if appliedRate == targetFrameRate { MirageLogger.host("Desktop stream refresh override applied: \(targetFrameRate)fps") } else {
                    MirageLogger
                        .host(
                            "Desktop stream refresh override pending: requested \(targetFrameRate)fps, applied \(appliedRate)fps"
                        )
                }
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to update desktop stream refresh rate: ")
            }
            return
        }

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for refresh rate change: \(streamID)")
            return
        }

        let currentRate = await context.encoderConfig.targetFrameRate
        guard currentRate != targetFrameRate || forceDisplayRefresh else { return }

        do {
            try await context.updateFrameRate(targetFrameRate)
            if forceDisplayRefresh, await context.isUsingVirtualDisplay {
                MirageLogger.host(
                    "Ignoring forceDisplayRefresh reconfigure for dedicated virtual-display stream \(streamID)"
                )
            }
            let appliedRate = await context.encoderConfig.targetFrameRate
            if appliedRate == targetFrameRate { MirageLogger.host("Stream refresh override applied: \(targetFrameRate)fps") } else {
                MirageLogger
                    .host("Stream refresh override pending: requested \(targetFrameRate)fps, applied \(appliedRate)fps")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update stream refresh rate: ")
        }
    }

    /// Applies client-requested encoder setting changes for an active stream.
    func handleStreamEncoderSettingsChange(
        _ request: StreamEncoderSettingsChangeMessage,
        from clientContext: ClientContext? = nil
    ) async {
        let resolvedStream: (streamID: StreamID, context: StreamContext)? = if let clientContext {
            await ownedStreamContext(for: request.streamID, clientContext: clientContext)
        } else if let context = streamsByID[request.streamID] {
            (request.streamID, context)
        } else {
            nil
        }

        guard let resolvedStream else {
            MirageLogger.debug(.host, "No stream found for encoder settings update: \(request.streamID)")
            return
        }
        let resolvedStreamID = resolvedStream.streamID
        let context = resolvedStream.context
        let isHostResolutionDesktopStream = resolvedStreamID == desktopStreamID && desktopUsesHostResolution
        let isAppAtlasMediaStream = isAppAtlasMediaStreamID(resolvedStreamID)

        let hasColorDepthChange = request.colorDepth != nil
        let hasBitrateChange = request.bitrate != nil
        let hasBitrateCeilingChange = request.bitrateAdaptationCeiling != nil
        let hasScaleChange = request.streamScale != nil && !isHostResolutionDesktopStream && !isAppAtlasMediaStream
        let hasFrameRateChange = request.targetFrameRate != nil
        let shouldBroadcastStreamUpdate = !isAppAtlasMediaStream &&
            (hasColorDepthChange || hasScaleChange || hasFrameRateChange)

        let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: request.bitrate)
        do {
            if request.streamID != resolvedStreamID {
                MirageLogger.host(
                    "Resolved encoder settings stream \(request.streamID) to media stream \(resolvedStreamID)"
                )
            }
            if hasColorDepthChange || hasBitrateChange || hasBitrateCeilingChange {
                try await context.updateEncoderSettings(
                    colorDepth: request.colorDepth,
                    bitrate: normalizedBitrate,
                    bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                    updateRequestedTargetBitrate: hasBitrateChange
                )
            }
            if let streamScale = request.streamScale {
                if isHostResolutionDesktopStream {
                    MirageLogger.host(
                        "Ignoring encoder settings streamScale for host-resolution desktop stream \(request.streamID): \(streamScale)"
                    )
                } else if isAppAtlasMediaStream {
                    MirageLogger.host(
                        "Ignoring encoder settings streamScale for app-atlas media stream \(resolvedStreamID) " +
                            "requested by stream \(request.streamID): \(streamScale)"
                    )
                } else {
                    try await context.updateStreamScale(StreamContext.clampStreamScale(streamScale))
                }
            }
            if let targetFrameRate = request.targetFrameRate {
                try await context.updateFrameRate(targetFrameRate)
            }
            if shouldBroadcastStreamUpdate {
                await sendStreamScaleUpdate(streamID: resolvedStreamID)
            } else if isAppAtlasMediaStream {
                MirageLogger.host(
                    "Encoder settings update applied to app-atlas media stream \(resolvedStreamID) " +
                        "from requested stream \(request.streamID) without stream resize notification"
                )
            } else {
                MirageLogger.host("Encoder settings update applied without stream resize notification (bitrate only)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to apply encoder settings update: ")
        }
    }

    private func isAppAtlasMediaStreamID(_ streamID: StreamID) -> Bool {
        appAtlasCoordinatorsByClientID.values.contains { $0.mediaStreamID == streamID }
    }

    /// Applies the client's desktop cursor presentation preference to the active desktop stream.
    func handleDesktopCursorPresentationChange(_ request: DesktopCursorPresentationChangeMessage) async {
        guard request.streamID == desktopStreamID,
              let context = desktopStreamContext else {
            MirageLogger.debug(.host, "Ignoring desktop cursor presentation update for inactive stream: \(request.streamID)")
            return
        }

        desktopCursorPresentation = request.cursorPresentation

        do {
            try await context.updateCaptureShowsCursor(request.cursorPresentation.capturesHostCursor)
            MirageLogger.host(
                "Desktop cursor presentation updated: source=\(request.cursorPresentation.source.rawValue), " +
                    "lockWhenHost=\(request.cursorPresentation.lockClientCursorWhenUsingHostCursor)"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update desktop cursor presentation: ")
        }
    }

    /// Refreshes cached virtual-display geometry for a window stream.
    func refreshWindowVirtualDisplayState(
        streamID: StreamID,
        context: StreamContext,
        clientScaleFactorOverride: CGFloat?,
        targetContentAspectRatioOverride: CGFloat? = nil
    )
    async {
        guard let geometry = await context.virtualDisplayGeometrySnapshot else { return }
        let snapshot = geometry.display
        let existingState = virtualDisplayState(streamID: streamID)

        var displayVisibleBounds = geometry.visibleBounds
        let capturePresentationRect = geometry.capturePresentationRect
        var captureSourceRect = geometry.captureSourceRect
        if displayVisibleBounds.isEmpty || captureSourceRect.isEmpty {
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: snapshot.resolution,
                scaleFactor: max(1.0, snapshot.scaleFactor)
            )
            let displayBounds = CGVirtualDisplayBridge.displayBounds(
                snapshot.displayID,
                knownResolution: logicalResolution
            )
            displayVisibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
                snapshot.displayID,
                knownBounds: displayBounds
            )
            displayVisibleBounds = displayVisibleBounds.intersection(displayBounds)
            if displayVisibleBounds.isEmpty {
                displayVisibleBounds = displayBounds
            }
            captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
                snapshot.displayID,
                knownBounds: displayBounds
            )
        }
        let resolvedClientScaleFactor = max(
            1.0,
            clientScaleFactorOverride ??
                existingState?.clientScaleFactor ??
                snapshot.scaleFactor
        )
        let targetContentAspectRatio = resolvedWindowTargetContentAspectRatio(
            existingAspectRatio: existingState?.targetContentAspectRatio,
            overrideAspectRatio: targetContentAspectRatioOverride
        )
        let windowID = geometry.windowID
        let effectiveBounds = if capturePresentationRect.width > 0, capturePresentationRect.height > 0 {
            capturePresentationRect.standardized
        } else {
            aspectFittedWindowBounds(
                displayVisibleBounds,
                targetAspectRatio: targetContentAspectRatio
            )
        }
        let effectivePixelResolution = CGSize(
            width: max(1, ceil(effectiveBounds.width * max(1.0, snapshot.scaleFactor))),
            height: max(1, ceil(effectiveBounds.height * max(1.0, snapshot.scaleFactor)))
        )
        let displayVisiblePixelResolution = CGSize(
            width: max(1, ceil(displayVisibleBounds.width * max(1.0, snapshot.scaleFactor))),
            height: max(1, ceil(displayVisibleBounds.height * max(1.0, snapshot.scaleFactor)))
        )
        let state = WindowVirtualDisplayState(
            streamID: streamID,
            displayID: snapshot.displayID,
            generation: snapshot.generation,
            bounds: effectiveBounds,
            displayVisibleBounds: displayVisibleBounds,
            targetContentAspectRatio: targetContentAspectRatio,
            captureSourceRect: captureSourceRect,
            visiblePixelResolution: effectivePixelResolution,
            displayVisiblePixelResolution: displayVisiblePixelResolution,
            scaleFactor: max(1.0, snapshot.scaleFactor),
            pixelResolution: snapshot.resolution,
            clientScaleFactor: resolvedClientScaleFactor
        )
        setVirtualDisplayState(windowID: windowID, state: state)
        inputStreamCache.updateWindowFrame(streamID, newFrame: effectiveBounds)
    }

    func refreshSharedDisplayAppCaptureStateIfNeeded(
        streamID: StreamID,
        reason: String,
        targetContentAspectRatioOverride: CGFloat? = nil
    ) async throws {
        guard let context = streamsByID[streamID] else { return }
        guard await context.isAppStream,
              await context.isUsingVirtualDisplay,
              await context.captureMode == .display else {
            return
        }

        try await context.refreshSharedDisplayAppCaptureLayout(label: reason)
        await refreshWindowVirtualDisplayState(
            streamID: streamID,
            context: context,
            clientScaleFactorOverride: nil,
            targetContentAspectRatioOverride: targetContentAspectRatioOverride
        )
        if let appSession = await appStreamManager.sessionForStreamID(streamID) {
            await appStreamManager.setCapturedClusterWindowIDs(
                bundleIdentifier: appSession.bundleIdentifier,
                streamID: streamID,
                capturedClusterWindowIDs: context.capturedWindowClusterWindowIDs
            )
        }
    }

    func refreshSharedDisplayAppCaptureStateBestEffort(
        streamID: StreamID,
        reason: String,
        targetContentAspectRatioOverride: CGFloat? = nil
    ) async {
        do {
            try await refreshSharedDisplayAppCaptureStateIfNeeded(
                streamID: streamID,
                reason: reason,
                targetContentAspectRatioOverride: targetContentAspectRatioOverride
            )
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to refresh shared-display app capture state for stream \(streamID): "
            )
        }
    }

    func sendStreamScaleUpdate(streamID: StreamID) async {
        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream scale update: \(streamID)")
            return
        }

        let streamStart = await context.streamStartSnapshot

        if streamID == desktopStreamID {
            if let clientContext = desktopStreamClientContext {
                guard let desktopSessionID else {
                    MirageLogger.error(.host, "Missing desktop session ID for desktopStreamStarted update on stream \(streamID)")
                    return
                }
                let displayResolution = await currentDesktopStartedResolution(
                    fallback: CGSize(
                        width: streamStart.encodedDimensions.width,
                        height: streamStart.encodedDimensions.height
                    )
                )
                let encodedResolution = CGSize(
                    width: streamStart.encodedDimensions.width,
                    height: streamStart.encodedDimensions.height
                )
                let geometryContract = reusableCurrentDesktopGeometryContract(
                    displayPixelResolution: displayResolution,
                    encodedPixelResolution: encodedResolution,
                    refreshTargetHz: streamStart.targetFrameRate
                )
                desktopPresentationGeneration &+= 1
                let message = DesktopStreamStartedMessage(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID,
                    width: Int(displayResolution.width),
                    height: Int(displayResolution.height),
                    frameRate: streamStart.targetFrameRate,
                    codec: streamStart.codec,
                    displayCount: 1,
                    dimensionToken: streamStart.dimensionToken,
                    acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
                    transitionPhase: .resize,
                    transitionOutcome: .resized,
                    desktopPresentationGeneration: desktopPresentationGeneration,
                    captureSource: desktopCaptureSource,
                    allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
                    acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
                    presentationWidth: Int(geometryContract.presentationResolution.width.rounded()),
                    presentationHeight: Int(geometryContract.presentationResolution.height.rounded()),
                    desktopGeometryContractID: geometryContract.contractID,
                    desktopGeometrySceneIdentity: geometryContract.sceneIdentity,
                    desktopGeometryDisplayPixelWidth: Int(geometryContract.displayPixelResolution.width.rounded()),
                    desktopGeometryDisplayPixelHeight: Int(geometryContract.displayPixelResolution.height.rounded()),
                    desktopGeometryEncodedPixelWidth: Int(geometryContract.encodedPixelResolution.width.rounded()),
                    desktopGeometryEncodedPixelHeight: Int(geometryContract.encodedPixelResolution.height.rounded()),
                    desktopGeometryRefreshTargetHz: geometryContract.refreshTargetHz ?? streamStart.targetFrameRate
                )
                if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
                    MirageLogger.error(.host, "Failed to encode desktopStreamStarted update for stream \(streamID)")
                } else if geometryContract.contractID == nil {
                    clearCurrentDesktopGeometryContract()
                } else {
                    recordCurrentDesktopGeometryContract(
                        contractID: geometryContract.contractID,
                        sceneIdentity: geometryContract.sceneIdentity,
                        presentationResolution: geometryContract.presentationResolution,
                        displayPixelResolution: geometryContract.displayPixelResolution,
                        encodedPixelResolution: geometryContract.encodedPixelResolution,
                        acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
                        refreshTargetHz: geometryContract.refreshTargetHz
                    )
                }
            }

            return
        }

        guard let session = activeSessionByStreamID[streamID] else { return }
        guard let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) else { return }

        let message = StreamStartedMessage(
            streamID: streamID,
            windowID: session.window.id,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            minWidth: nil,
            minHeight: nil,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
        )
        do {
            try await clientContext.send(.streamStarted, content: message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send streamStarted update: ")
        }
    }

    func sendStreamCadenceUpdate(streamID: StreamID) async {
        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream cadence update: \(streamID)")
            return
        }
        guard streamID == desktopStreamID else { return }
        guard let clientContext = desktopStreamClientContext else { return }
        guard let desktopSessionID else {
            MirageLogger.error(.host, "Missing desktop session ID for cadence update on stream \(streamID)")
            return
        }

        let streamStart = await context.streamStartSnapshot
        let displayResolution = await currentDesktopStartedResolution(
            fallback: CGSize(
                width: streamStart.encodedDimensions.width,
                height: streamStart.encodedDimensions.height
            )
        )
        let encodedResolution = CGSize(
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height
        )
        let geometryContract = reusableCurrentDesktopGeometryContract(
            displayPixelResolution: displayResolution,
            encodedPixelResolution: encodedResolution,
            refreshTargetHz: streamStart.targetFrameRate
        )
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(displayResolution.width),
            height: Int(displayResolution.height),
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            displayCount: 1,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
            captureSource: desktopCaptureSource,
            allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
            acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
            presentationWidth: Int(geometryContract.presentationResolution.width.rounded()),
            presentationHeight: Int(geometryContract.presentationResolution.height.rounded()),
            desktopGeometryContractID: geometryContract.contractID,
            desktopGeometrySceneIdentity: geometryContract.sceneIdentity,
            desktopGeometryDisplayPixelWidth: Int(geometryContract.displayPixelResolution.width.rounded()),
            desktopGeometryDisplayPixelHeight: Int(geometryContract.displayPixelResolution.height.rounded()),
            desktopGeometryEncodedPixelWidth: Int(geometryContract.encodedPixelResolution.width.rounded()),
            desktopGeometryEncodedPixelHeight: Int(geometryContract.encodedPixelResolution.height.rounded()),
            desktopGeometryRefreshTargetHz: geometryContract.refreshTargetHz ?? streamStart.targetFrameRate
        )
        if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            MirageLogger.error(.host, "Failed to encode desktop cadence update for stream \(streamID)")
        }
    }
}

#endif
