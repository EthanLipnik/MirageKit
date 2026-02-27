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

enum DesktopResizeNoOpDecision: Equatable {
    case noOp
    case apply
}

func desktopResizeNoOpDecision(
    currentResolution: CGSize?,
    currentRefreshRate: Int?,
    requestedResolution: CGSize,
    requestedRefreshRate: Int
)
-> DesktopResizeNoOpDecision {
    guard let currentResolution, let currentRefreshRate else { return .apply }
    guard requestedResolution.width > 0, requestedResolution.height > 0 else { return .noOp }
    if currentResolution == requestedResolution, currentRefreshRate == requestedRefreshRate {
        return .noOp
    }
    return .apply
}

enum DesktopResizeMirroringPlan: Equatable {
    case suspendAndRestore
    case unchanged
}

func desktopResizeMirroringPlan(for mode: MirageDesktopStreamMode) -> DesktopResizeMirroringPlan {
    if mode == .mirrored { return .suspendAndRestore }
    return .unchanged
}

enum WindowResizeNoOpDecision: Equatable {
    case noOp
    case apply
}

private func virtualDisplayResolutionMatches(
    _ lhs: CGSize,
    _ rhs: CGSize,
    tolerance: CGFloat = 2
) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
}

func windowResizeNoOpDecision(
    currentVisibleResolution: CGSize?,
    currentDisplayResolution: CGSize?,
    requestedVisibleResolution: CGSize
)
-> WindowResizeNoOpDecision {
    guard requestedVisibleResolution.width > 0, requestedVisibleResolution.height > 0 else { return .noOp }
    if let currentVisibleResolution,
       virtualDisplayResolutionMatches(currentVisibleResolution, requestedVisibleResolution) {
        return .noOp
    }
    if let currentDisplayResolution,
       virtualDisplayResolutionMatches(currentDisplayResolution, requestedVisibleResolution) {
        return .noOp
    }
    return .apply
}

func aspectFittedWindowBounds(
    _ bounds: CGRect,
    targetAspectRatio: CGFloat?
) -> CGRect {
    guard let targetAspectRatio,
          targetAspectRatio.isFinite,
          targetAspectRatio > 0,
          bounds.width > 0,
          bounds.height > 0 else {
        return bounds
    }

    let currentAspect = bounds.width / bounds.height
    guard abs(currentAspect - targetAspectRatio) > 0.0001 else { return bounds }

    var fittedWidth = bounds.width
    var fittedHeight = bounds.height
    if currentAspect > targetAspectRatio {
        fittedWidth = floor(bounds.height * targetAspectRatio)
    } else {
        fittedHeight = floor(bounds.width / targetAspectRatio)
    }

    fittedWidth = max(1, fittedWidth)
    fittedHeight = max(1, fittedHeight)
    let originX = bounds.minX + (bounds.width - fittedWidth) * 0.5
    let originY = bounds.minY + (bounds.height - fittedHeight) * 0.5
    return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
}

func requestedAspectRatioForWindowFit(
    requestedPixelResolution: CGSize,
    visiblePixelResolution: CGSize,
    displayPixelResolution: CGSize? = nil,
    mismatchTolerance: CGFloat = 0.002
) -> CGFloat? {
    func hasMatchingPixelArea(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        let lhsWidth = Int64(lhs.width.rounded())
        let lhsHeight = Int64(lhs.height.rounded())
        let rhsWidth = Int64(rhs.width.rounded())
        let rhsHeight = Int64(rhs.height.rounded())
        guard lhsWidth > 0, lhsHeight > 0, rhsWidth > 0, rhsHeight > 0 else {
            return false
        }
        return lhsWidth * lhsHeight == rhsWidth * rhsHeight
    }

    func isCloseToRequested(_ requested: CGSize, _ candidate: CGSize, relativeTolerance: CGFloat = 0.12) -> Bool {
        guard requested.width > 0, requested.height > 0 else { return false }
        let widthDelta = abs(candidate.width - requested.width) / requested.width
        let heightDelta = abs(candidate.height - requested.height) / requested.height
        return widthDelta <= relativeTolerance && heightDelta <= relativeTolerance
    }

    guard requestedPixelResolution.width > 0,
          requestedPixelResolution.height > 0,
          visiblePixelResolution.width > 0,
          visiblePixelResolution.height > 0 else {
        return nil
    }

    let requestedAspect = requestedPixelResolution.width / requestedPixelResolution.height
    let visibleAspect = visiblePixelResolution.width / visiblePixelResolution.height
    guard requestedAspect.isFinite, visibleAspect.isFinite, requestedAspect > 0, visibleAspect > 0 else {
        return nil
    }

    let relativeDelta = abs(requestedAspect - visibleAspect) / requestedAspect
    guard relativeDelta > mismatchTolerance else { return nil }

    if let displayPixelResolution,
       displayPixelResolution.width > 0,
       displayPixelResolution.height > 0 {
        let displayWidthDelta = abs(displayPixelResolution.width - requestedPixelResolution.width)
        let displayHeightDelta = abs(displayPixelResolution.height - requestedPixelResolution.height)
        if displayWidthDelta <= 2, displayHeightDelta <= 2 {
            // Inset-only visible-area reduction on an otherwise exact display request.
            // Keep the app window filling the calibrated visible frame instead of forcing
            // pillar/letterboxing to the requested display aspect.
            return nil
        }

        // Only apply aspect-fit when we intentionally accepted a near-by Retina
        // mode with matching pixel area but different aspect ratio.
        // If the display mode diverges in total area, prefer full visible-frame fill.
        guard hasMatchingPixelArea(requestedPixelResolution, displayPixelResolution),
              isCloseToRequested(requestedPixelResolution, displayPixelResolution) else {
            return nil
        }
    }
    return requestedAspect
}

private enum DesktopResizeTransactionAbort: Error {
    case streamNoLongerActive
}

extension MirageHostService {
    private func virtualDisplayScaleFactor(for _: MirageConnectedClient?) -> CGFloat {
        max(1.0, sharedVirtualDisplayScaleFactor)
    }

    func virtualDisplayPixelResolution(
        for logicalResolution: CGSize,
        client: MirageConnectedClient?,
        scaleFactorOverride: CGFloat? = nil
    )
    -> CGSize {
        guard logicalResolution.width > 0, logicalResolution.height > 0 else { return logicalResolution }
        let scale: CGFloat = if let scaleFactorOverride, scaleFactorOverride > 0 {
            max(1.0, scaleFactorOverride)
        } else {
            virtualDisplayScaleFactor(for: client)
        }
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
            MirageLogger.error(.host, error: error, message: "Failed to send content bounds update: ")
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

        let inheritedClientScaleFactor = clientVirtualDisplayScaleFactor(streamID: originalStreamID)
        var displayResolution = window.frame.size
        if let cachedState = getVirtualDisplayState(streamID: originalStreamID),
           cachedState.bounds.width > 0,
           cachedState.bounds.height > 0 {
            displayResolution = cachedState.bounds.size
        } else if let inheritedSnapshot = await originalContext.getVirtualDisplaySnapshot() {
            displayResolution = SharedVirtualDisplayManager.logicalResolution(
                for: inheritedSnapshot.resolution,
                scaleFactor: max(1.0, inheritedSnapshot.scaleFactor)
            )
        }
        let streamScale = await originalContext.getStreamScale()
        let disableResolutionCap = await originalContext.isResolutionCapDisabled()
        let encoderSettings = await originalContext.getEncoderSettings()
        let targetFrameRate = await originalContext.getTargetFrameRate()
        let audioConfiguration = audioConfigurationByClientID[client.id] ?? .default

        // Auto-start a new stream for this window
        do {
            _ = try await startStream(
                for: window,
                to: client,
                dataPort: nil,
                clientDisplayResolution: displayResolution,
                clientScaleFactor: inheritedClientScaleFactor,
                keyFrameInterval: encoderSettings.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate,
                bitDepth: encoderSettings.bitDepth,
                captureQueueDepth: encoderSettings.captureQueueDepth,
                bitrate: encoderSettings.bitrate,
                latencyMode: encoderSettings.latencyMode,
                performanceMode: encoderSettings.performanceMode,
                lowLatencyHighResolutionCompressionBoost: encoderSettings
                    .lowLatencyHighResolutionCompressionBoostEnabled,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration
            )
            MirageLogger.host("Auto-started stream for new independent window \(window.id)")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to auto-start stream for new window: ")
        }
    }

    func handleStreamScaleChange(streamID: StreamID, streamScale: CGFloat) async {
        let clampedScale = max(0.1, min(1.0, streamScale))

        guard let context = streamsByID[streamID] else {
            MirageLogger.debug(.host, "No stream found for stream scale change: \(streamID)")
            return
        }
        let usesVirtualDisplay = await context.isUsingVirtualDisplay()
        let contextWindowID = await context.getWindowID()
        let isDedicatedVirtualDisplayStream = usesVirtualDisplay && contextWindowID != 0
        if isDedicatedVirtualDisplayStream {
            MirageLogger.host(
                "Ignoring stream scale change for dedicated virtual-display stream \(streamID): \(clampedScale)"
            )
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
            MirageLogger.error(.host, error: error, message: "Failed to update stream scale: ")
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
                    if let snapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot() {
                        sharedVirtualDisplayScaleFactor = max(1.0, snapshot.scaleFactor)
                    }
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
                MirageLogger.error(.host, error: error, message: "Failed to update desktop stream refresh rate: ")
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
            registerAppStreamDesiredFrameRate(streamID: streamID, frameRate: targetFrameRate)
            await refreshAppStreamActivity(streamID: streamID, reason: "refreshOverride")
            if forceDisplayRefresh, await context.isUsingVirtualDisplay() {
                MirageLogger.host(
                    "Ignoring forceDisplayRefresh reconfigure for dedicated virtual-display stream \(streamID)"
                )
            }
            let appliedRate = await context.getTargetFrameRate()
            if appliedRate == targetFrameRate { MirageLogger.host("Stream refresh override applied: \(targetFrameRate)fps") } else {
                MirageLogger
                    .host("Stream refresh override pending: requested \(targetFrameRate)fps, applied \(appliedRate)fps")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update stream refresh rate: ")
        }
    }

    func handleStreamEncoderSettingsChange(_ request: StreamEncoderSettingsChangeMessage) async {
        guard let context = streamsByID[request.streamID] else {
            MirageLogger.debug(.host, "No stream found for encoder settings update: \(request.streamID)")
            return
        }
        let usesVirtualDisplay = await context.isUsingVirtualDisplay()
        let contextWindowID = await context.getWindowID()
        let isDedicatedVirtualDisplayStream = usesVirtualDisplay && contextWindowID != 0

        let hasBitDepthChange = request.bitDepth != nil
        let hasBitrateChange = request.bitrate != nil
        let hasScaleChange = request.streamScale != nil && !isDedicatedVirtualDisplayStream
        let shouldBroadcastStreamUpdate = hasBitDepthChange || hasScaleChange

        let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: request.bitrate)
        do {
            if hasBitDepthChange || hasBitrateChange {
                try await context.updateEncoderSettings(
                    bitDepth: request.bitDepth,
                    bitrate: normalizedBitrate
                )
            }
            if let streamScale = request.streamScale {
                if isDedicatedVirtualDisplayStream {
                    MirageLogger.host(
                        "Ignoring encoder settings streamScale for dedicated virtual-display stream \(request.streamID): \(streamScale)"
                    )
                } else {
                    try await context.updateStreamScale(StreamContext.clampStreamScale(streamScale))
                }
            }
            if shouldBroadcastStreamUpdate {
                await sendStreamScaleUpdate(streamID: request.streamID)
            } else {
                MirageLogger.host("Encoder settings update applied without stream resize notification (bitrate only)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to apply encoder settings update: ")
        }
    }

    func refreshWindowVirtualDisplayState(
        streamID: StreamID,
        context: StreamContext,
        clientScaleFactorOverride: CGFloat?
    )
    async {
        guard let snapshot = await context.getVirtualDisplaySnapshot() else { return }
        let existingState = getVirtualDisplayState(streamID: streamID)

        var bounds = await context.getVirtualDisplayVisibleBounds()
        var captureSourceRect = await context.getVirtualDisplayCaptureSourceRect()
        var visiblePixelResolution = await context.getVirtualDisplayVisiblePixelResolution()
        if bounds.isEmpty || captureSourceRect.isEmpty || visiblePixelResolution == .zero {
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: snapshot.resolution,
                scaleFactor: max(1.0, snapshot.scaleFactor)
            )
            let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                snapshot.displayID,
                knownResolution: logicalResolution
            )
            bounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
                snapshot.displayID,
                knownBounds: displayBounds
            )
            bounds = bounds.intersection(displayBounds)
            if bounds.isEmpty {
                bounds = displayBounds
            }
            captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
                snapshot.displayID,
                knownBounds: displayBounds
            )
            visiblePixelResolution = CGSize(
                width: max(1, ceil(bounds.width * max(1.0, snapshot.scaleFactor))),
                height: max(1, ceil(bounds.height * max(1.0, snapshot.scaleFactor)))
            )
        }
        let resolvedClientScaleFactor = max(
            1.0,
            clientScaleFactorOverride ??
                existingState?.clientScaleFactor ??
                snapshot.scaleFactor
        )
        let windowID = await context.getWindowID()
        let effectiveBounds = aspectFittedWindowBounds(
            bounds,
            targetAspectRatio: existingState?.targetContentAspectRatio
        )
        let state = WindowVirtualDisplayState(
            streamID: streamID,
            displayID: snapshot.displayID,
            generation: snapshot.generation,
            bounds: effectiveBounds,
            targetContentAspectRatio: existingState?.targetContentAspectRatio,
            captureSourceRect: captureSourceRect,
            visiblePixelResolution: visiblePixelResolution,
            scaleFactor: max(1.0, snapshot.scaleFactor),
            pixelResolution: snapshot.resolution,
            clientScaleFactor: resolvedClientScaleFactor
        )
        setVirtualDisplayState(windowID: windowID, state: state)
        inputStreamCacheActor.updateWindowFrame(streamID, newFrame: effectiveBounds)
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
                if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
                    MirageLogger.error(.host, "Failed to encode desktopStreamStarted update for stream \(streamID)")
                }
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

        guard let session = activeSessionByStreamID[streamID] else { return }
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

    func resetDesktopResizeTransactionState() {
        pendingDesktopResizeResolution = nil
        desktopResizeInFlight = false
    }

    private func enqueueDesktopResolutionChange(streamID: StreamID, logicalResolution: CGSize) async {
        guard streamID == desktopStreamID else { return }

        pendingDesktopResizeResolution = logicalResolution
        desktopResizeRequestCounter &+= 1
        let requestNumber = desktopResizeRequestCounter
        MirageLogger
            .host(
                "Queued desktop resize request #\(requestNumber): " +
                    "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts"
            )

        guard !desktopResizeInFlight else { return }
        desktopResizeInFlight = true
        defer { desktopResizeInFlight = false }

        while let pendingResolution = pendingDesktopResizeResolution {
            pendingDesktopResizeResolution = nil
            let latestRequestNumber = desktopResizeRequestCounter
            await applyDesktopResolutionChange(
                streamID: streamID,
                logicalResolution: pendingResolution,
                requestNumber: latestRequestNumber
            )

            guard desktopStreamID == streamID, desktopStreamContext != nil else {
                pendingDesktopResizeResolution = nil
                return
            }
        }
    }

    private func applyDesktopResolutionChange(
        streamID: StreamID,
        logicalResolution: CGSize,
        requestNumber: UInt64
    )
    async {
        guard streamID == desktopStreamID, let desktopContext = desktopStreamContext else { return }

        let mirroringPlan = desktopResizeMirroringPlan(for: desktopStreamMode)
        var suspendedMirroringDisplayID: CGDirectDisplayID?
        var shouldRestoreMirroring = false
        var resizeCompletionContext: StreamContext?
        var shouldStopDesktopStreamWithError = false
        var shouldResumeEncodingAfterResize = false
        do {
            let pixelResolution = virtualDisplayPixelResolution(
                for: logicalResolution,
                client: desktopStreamClientContext?.client,
                scaleFactorOverride: desktopRequestedScaleFactor
            )
            let targetFrameRate = await desktopContext.getTargetFrameRate()
            let streamRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: targetFrameRate)
            let preResizeSnapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot()
            let noOpDecision = desktopResizeNoOpDecision(
                currentResolution: preResizeSnapshot?.resolution,
                currentRefreshRate: preResizeSnapshot.map { Int($0.refreshRate.rounded()) },
                requestedResolution: pixelResolution,
                requestedRefreshRate: streamRefreshRate
            )
            if noOpDecision == .noOp {
                MirageLogger
                    .host(
                        "Desktop stream resize skipped (already " +
                            "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                            "\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px @\(streamRefreshRate)Hz)"
                    )
                await sendDesktopResizeCompletion(
                    streamID: streamID,
                    requestNumber: requestNumber,
                    context: desktopContext,
                    noOp: true
                )
                return
            }

            MirageLogger
                .host(
                    "Desktop stream resize requested (#\(requestNumber)): " +
                        "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                        "(\(Int(pixelResolution.width))x\(Int(pixelResolution.height)) px)"
                )
            await desktopContext.suspendEncodingForDesktopResize()
            shouldResumeEncodingAfterResize = true

            if mirroringPlan == .suspendAndRestore, let displayID = preResizeSnapshot?.displayID {
                await suspendDisplayMirroringForResize(targetDisplayID: displayID)
                suspendedMirroringDisplayID = displayID
                shouldRestoreMirroring = true
            }

            try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                for: .desktopStream,
                newResolution: pixelResolution,
                refreshRate: streamRefreshRate
            )

            guard streamID == desktopStreamID else { throw DesktopResizeTransactionAbort.streamNoLongerActive }

            guard let postResizeSnapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot() else {
                throw MirageError.protocolError("Missing shared display snapshot after desktop resize")
            }

            sharedVirtualDisplayScaleFactor = max(1.0, postResizeSnapshot.scaleFactor)
            sharedVirtualDisplayGeneration = postResizeSnapshot.generation

            let effectivePixelResolution = postResizeSnapshot.resolution
            let activeDisplayID = postResizeSnapshot.displayID

            if shouldRestoreMirroring,
               streamID == desktopStreamID,
               desktopStreamMode == .mirrored {
                let mirroringRestored = await restoreDisplayMirroringAfterResize(targetDisplayID: activeDisplayID)
                guard mirroringRestored else {
                    throw MirageError.protocolError(
                        "Failed to restore display mirroring after desktop resize"
                    )
                }
                shouldRestoreMirroring = false
            }

            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
            guard streamID == desktopStreamID, let latestDesktopContext = desktopStreamContext else {
                throw DesktopResizeTransactionAbort.streamNoLongerActive
            }
            try await latestDesktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: effectivePixelResolution
            )
            if captureDisplay.display.displayID != activeDisplayID {
                MirageLogger
                    .host(
                        "Desktop resize reset captured display \(captureDisplay.display.displayID) while shared display is \(activeDisplayID)"
                    )
            }

            let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
            let inputBounds = resolvedDesktopInputBounds(
                physicalBounds: primaryBounds,
                virtualResolution: effectivePixelResolution
            )
            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: inputBounds)
            if mirroringPlan == .unchanged,
               !mirroredPhysicalDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: activeDisplayID)
            }
            MirageLogger
                .host(
                    "Desktop stream resized to " +
                        "\(Int(logicalResolution.width))x\(Int(logicalResolution.height)) pts " +
                        "(\(Int(effectivePixelResolution.width))x\(Int(effectivePixelResolution.height)) px), input bounds: \(inputBounds)"
                )
            resizeCompletionContext = latestDesktopContext
        } catch DesktopResizeTransactionAbort.streamNoLongerActive {
            MirageLogger.host("Desktop resize transaction #\(requestNumber) aborted because stream is no longer active")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to resize desktop stream: ")
            shouldStopDesktopStreamWithError = streamID == desktopStreamID
        }

        if shouldRestoreMirroring {
            let restoreDisplayID = await SharedVirtualDisplayManager.shared.getDisplayID() ?? suspendedMirroringDisplayID
            if let restoreDisplayID {
                if shouldStopDesktopStreamWithError {
                    await disableDisplayMirroring(displayID: restoreDisplayID)
                } else if streamID == desktopStreamID, desktopStreamMode == .mirrored {
                    await setupDisplayMirroring(targetDisplayID: restoreDisplayID)
                } else if !mirroredPhysicalDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                    await disableDisplayMirroring(displayID: restoreDisplayID)
                }
            }
        }

        if shouldStopDesktopStreamWithError, streamID == desktopStreamID {
            shouldResumeEncodingAfterResize = false
            await stopDesktopStream(reason: .error)
            return
        }

        if let resizeCompletionContext,
           streamID == desktopStreamID {
            await sendDesktopResizeCompletion(
                streamID: streamID,
                requestNumber: requestNumber,
                context: resizeCompletionContext,
                noOp: false
            )
            if shouldResumeEncodingAfterResize {
                await resizeCompletionContext.resumeEncodingAfterDesktopResize()
                shouldResumeEncodingAfterResize = false
            }
        }

        if shouldResumeEncodingAfterResize,
           streamID == desktopStreamID,
           let latestDesktopContext = desktopStreamContext {
            await latestDesktopContext.resumeEncodingAfterDesktopResize()
        }
    }

    private func sendDesktopResizeCompletion(
        streamID: StreamID,
        requestNumber: UInt64,
        context: StreamContext,
        noOp: Bool
    )
    async {
        guard let clientContext = desktopStreamClientContext else { return }

        let dimensionToken = await context.getDimensionToken()
        let encodedDimensions = await context.getEncodedDimensions()
        let updatedTargetFrameRate = await context.getTargetFrameRate()
        let codec = await context.getCodec()
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: updatedTargetFrameRate,
            codec: codec,
            displayCount: 1,
            dimensionToken: dimensionToken
        )
        if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            MirageLogger.error(.host, "Failed to encode desktop resize completion for stream \(streamID)")
            return
        }
        let suffix = noOp ? ", no-op" : ""
        MirageLogger.host("Sent desktop resize completion for stream \(streamID) (request #\(requestNumber)\(suffix))")
    }

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

    private func applyWindowResolutionChange(
        streamID: StreamID,
        logicalResolution: CGSize,
        requestNumber: UInt64
    )
    async {
        guard let context = streamsByID[streamID] else { return }
        guard let session = activeSessionByStreamID[streamID] else { return }
        let client = session.client
        let clientScaleOverride = clientVirtualDisplayScaleFactor(streamID: streamID)
        let pixelResolution = virtualDisplayPixelResolution(
            for: logicalResolution,
            client: client,
            scaleFactorOverride: clientScaleOverride
        )
        let currentState = getVirtualDisplayState(streamID: streamID)
        let currentVisibleResolution = currentState?.visiblePixelResolution
        let currentDisplayResolution = currentState?.pixelResolution
        if windowResizeNoOpDecision(
            currentVisibleResolution: currentVisibleResolution,
            currentDisplayResolution: currentDisplayResolution,
            requestedVisibleResolution: pixelResolution
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
            try await context.updateVirtualDisplayResolution(newResolution: pixelResolution)
            await refreshWindowVirtualDisplayState(
                streamID: streamID,
                context: context,
                clientScaleFactorOverride: clientScaleOverride
            )
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
                    message: "Failed to update dedicated display for stream \(streamID): \(error.localizedDescription)",
                    streamID: streamID
                )
                try? await clientContext.send(.error, content: errorMessage)
            }
            let keepStreamAlive: Bool
            if let resizeError = error as? StreamContext.VirtualDisplayResizeError {
                switch resizeError {
                case .rollbackFailed:
                    keepStreamAlive = false
                }
            } else {
                keepStreamAlive = true
            }

            if keepStreamAlive {
                // Fail-open for recoverable app/window display resize errors: keep the stream
                // alive with the last known-good capture pipeline and report a no-op completion.
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
            } else {
                let resizeFailureReason = error.localizedDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let appSession = await appStreamManager.getSessionForStreamID(streamID),
                   let clientContext = findClientContext(clientID: appSession.clientID) {
                    await emitWindowStreamFailed(
                        to: clientContext,
                        bundleIdentifier: appSession.bundleIdentifier,
                        windowID: session.window.id,
                        title: session.window.title,
                        reason: resizeFailureReason.isEmpty ? "Dedicated display resize failed" : resizeFailureReason
                    )
                }
                await stopStream(session, minimizeWindow: false)
            }
        }
    }

    private func sendWindowResizeCompletion(
        streamID: StreamID,
        requestNumber: UInt64,
        context: StreamContext,
        noOp: Bool
    )
    async {
        guard let currentSession = activeSessionByStreamID[streamID] else { return }
        guard let clientContext = findClientContext(clientID: currentSession.client.id) else { return }

        let resolvedWindowFrame = getVirtualDisplayBounds(windowID: currentSession.window.id)
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
        inputStreamCacheActor.updateWindowFrame(streamID, newFrame: updatedWindow.frame)

        let minSize = minimumSizesByWindowID[updatedWindow.id]
        let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
        let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
        let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))
        let dimensionToken = await context.getDimensionToken()
        let encodedDimensions = await context.getEncodedDimensions()
        let frameRate = await context.getTargetFrameRate()
        let codec = await context.getCodec()
        let message = StreamStartedMessage(
            streamID: streamID,
            windowID: updatedWindow.id,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: frameRate,
            codec: codec,
            minWidth: minWidth,
            minHeight: minHeight,
            dimensionToken: dimensionToken
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

    func ensureWindowVisibleFrameMonitor(streamID: StreamID) {
        guard windowVisibleFrameMonitorTasks[streamID] == nil else { return }
        windowVisibleFrameMonitorTasks[streamID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var driftCandidate: CGSize = .zero
            var driftCandidateSince = Date.distantPast
            var lastAppliedAt: CFAbsoluteTime = 0
            let driftTolerancePixels: CGFloat = 8
            let debounceDelay: TimeInterval = 0.75
            let cooldown: CFAbsoluteTime = 2.0

            while !Task.isCancelled {
                guard let state = getVirtualDisplayState(streamID: streamID) else { break }
                guard let windowID = activeWindowIDByStreamID[streamID] else { break }
                let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
                    state.displayID,
                    knownResolution: SharedVirtualDisplayManager.logicalResolution(
                        for: state.pixelResolution,
                        scaleFactor: max(1.0, state.scaleFactor)
                    )
                )
                var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
                    state.displayID,
                    knownBounds: displayBounds
                )
                visibleBounds = visibleBounds.intersection(displayBounds)
                if visibleBounds.isEmpty {
                    visibleBounds = displayBounds
                }
                let currentVisiblePixels = CGSize(
                    width: max(1, ceil(visibleBounds.width * max(1.0, state.scaleFactor))),
                    height: max(1, ceil(visibleBounds.height * max(1.0, state.scaleFactor)))
                )

                let widthDelta = abs(currentVisiblePixels.width - state.visiblePixelResolution.width)
                let heightDelta = abs(currentVisiblePixels.height - state.visiblePixelResolution.height)
                let displayWidthDelta = abs(currentVisiblePixels.width - state.pixelResolution.width)
                let displayHeightDelta = abs(currentVisiblePixels.height - state.pixelResolution.height)
                let directVisibleMatch = widthDelta <= driftTolerancePixels && heightDelta <= driftTolerancePixels
                let displayPixelMatch = displayWidthDelta <= driftTolerancePixels && displayHeightDelta <=
                    driftTolerancePixels
                let drifted = !(directVisibleMatch || displayPixelMatch)
                if drifted {
                    let desiredLogicalResolution = CGSize(
                        width: max(1, state.pixelResolution.width / max(1.0, state.clientScaleFactor)),
                        height: max(1, state.pixelResolution.height / max(1.0, state.clientScaleFactor))
                    )
                    if driftCandidate == .zero || driftCandidate != desiredLogicalResolution {
                        driftCandidate = desiredLogicalResolution
                        driftCandidateSince = Date()
                    } else {
                        let now = CFAbsoluteTimeGetCurrent()
                        if Date().timeIntervalSince(driftCandidateSince) >= debounceDelay,
                           now - lastAppliedAt >= cooldown,
                           !windowResizeInFlightStreamIDs.contains(streamID) {
                            lastAppliedAt = now
                            driftCandidate = .zero
                            driftCandidateSince = .distantPast
                            await enqueueWindowResolutionChange(
                                streamID: streamID,
                                logicalResolution: desiredLogicalResolution
                            )
                        }
                    }
                } else {
                    driftCandidate = .zero
                    driftCandidateSince = .distantPast
                }

                await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)

                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    break
                }
            }
            windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
        }
    }

    func stopWindowVisibleFrameMonitor(streamID: StreamID) {
        windowVisibleFrameMonitorTasks[streamID]?.cancel()
        windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
    }

    /// Handle display resolution change from client
    func handleDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async {
        if streamID == desktopStreamID {
            await enqueueDesktopResolutionChange(streamID: streamID, logicalResolution: newResolution)
            return
        }

        guard streamsByID[streamID] != nil else {
            MirageLogger.debug(.host, "No stream found for display resolution change: \(streamID)")
            return
        }
        await enqueueWindowResolutionChange(streamID: streamID, logicalResolution: newResolution)
    }
}

#endif
