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

enum DesktopResizeTransactionContinuationDecision: Equatable {
    case continueTransaction
    case abortStreamInactive
}

func desktopResizeTransactionContinuationDecision(
    requestedStreamID: StreamID,
    activeDesktopStreamID: StreamID?,
    hasDesktopContext: Bool
) -> DesktopResizeTransactionContinuationDecision {
    guard requestedStreamID == activeDesktopStreamID, hasDesktopContext else {
        return .abortStreamInactive
    }
    return .continueTransaction
}

struct DesktopBackingScaleResolution: Equatable {
    let scaleFactor: CGFloat
    let pixelResolution: CGSize
}

func resolvedHostLogicalDisplayResolution(
    bounds: CGRect,
    modeLogicalResolution: CGSize?
) -> CGSize? {
    if let modeLogicalResolution,
       modeLogicalResolution.width > 0,
       modeLogicalResolution.height > 0 {
        return modeLogicalResolution
    }

    guard bounds.width > 0, bounds.height > 0 else { return nil }
    return bounds.size
}

func resolvedDesktopBackingScaleResolution(
    logicalResolution: CGSize,
    defaultScaleFactor: CGFloat
) -> DesktopBackingScaleResolution {
    let geometry = MirageStreamGeometry.resolve(
        logicalSize: logicalResolution,
        displayScaleFactor: defaultScaleFactor
    )

    return DesktopBackingScaleResolution(
        scaleFactor: max(1.0, defaultScaleFactor),
        pixelResolution: geometry.displayPixelSize
    )
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
    currentEncodedResolution: CGSize?,
    requestedVisibleResolution: CGSize,
    requestedEncodedResolution: CGSize? = nil
)
-> WindowResizeNoOpDecision {
    guard requestedVisibleResolution.width > 0, requestedVisibleResolution.height > 0 else { return .noOp }
    let canonicalRequestedResolution = MirageStreamGeometry.alignedEncodedSize(requestedVisibleResolution)
    let canonicalRequestedEncodedResolution = requestedEncodedResolution.map(MirageStreamGeometry.alignedEncodedSize)
        ?? canonicalRequestedResolution
    if let currentEncodedResolution,
       !virtualDisplayResolutionMatches(currentEncodedResolution, canonicalRequestedEncodedResolution) {
        MirageLogger.host(
            "Window resize no-op rejected due to encoded-size mismatch: encoded=\(currentEncodedResolution), requested=\(canonicalRequestedEncodedResolution)"
        )
        return .apply
    }
    // Prefer the calibrated visible pixel size for no-op decisions.
    // Falling back to display pixels is only safe when visible pixels are unavailable.
    if let currentVisibleResolution {
        if virtualDisplayResolutionMatches(currentVisibleResolution, canonicalRequestedResolution) {
            return .noOp
        }
        return .apply
    }
    if let currentDisplayResolution,
       virtualDisplayResolutionMatches(currentDisplayResolution, canonicalRequestedResolution) {
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

    func currentDesktopStartedResolution(fallback: CGSize? = nil) async -> CGSize {
        if let snapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot() {
            return snapshot.resolution
        }
        if let fallback,
           fallback.width > 0,
           fallback.height > 0 {
            return fallback
        }
        return .zero
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
        guard let clientContext = clientsBySessionID.values.first(where: { $0.client.id == client.id }) else { return }

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
        let mediaMaxPacketSize = await originalContext.getMediaMaxPacketSize()
        let audioConfiguration = audioConfigurationByClientID[client.id] ?? .default

        // Auto-start a new stream for this window
        do {
            try await startStream(
                for: window,
                to: client,
                clientDisplayResolution: displayResolution,
                clientScaleFactor: inheritedClientScaleFactor,
                keyFrameInterval: encoderSettings.keyFrameInterval,
                streamScale: streamScale,
                targetFrameRate: targetFrameRate,
                colorDepth: encoderSettings.colorDepth,
                captureQueueDepth: encoderSettings.captureQueueDepth,
                bitrate: encoderSettings.bitrate,
                latencyMode: encoderSettings.latencyMode,
                performanceMode: encoderSettings.performanceMode,
                lowLatencyHighResolutionCompressionBoost: encoderSettings
                    .lowLatencyHighResolutionCompressionBoostEnabled,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration,
                mediaMaxPacketSize: mediaMaxPacketSize
            )
            MirageLogger.host("Auto-started stream for new independent window \(window.id)")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to auto-start stream for new window: ")
        }
    }

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

        let hasColorDepthChange = request.colorDepth != nil
        let hasBitrateChange = request.bitrate != nil
        let hasScaleChange = request.streamScale != nil && !isDedicatedVirtualDisplayStream
        let shouldBroadcastStreamUpdate = hasColorDepthChange || hasScaleChange

        let normalizedBitrate = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: request.bitrate)
        do {
            if hasColorDepthChange || hasBitrateChange {
                try await context.updateEncoderSettings(
                    colorDepth: request.colorDepth,
                    bitrate: normalizedBitrate,
                    updateRequestedTargetBitrate: hasBitrateChange
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
                let displayResolution = await currentDesktopStartedResolution(
                    fallback: CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
                )
                let message = await DesktopStreamStartedMessage(
                    streamID: streamID,
                    width: Int(displayResolution.width),
                    height: Int(displayResolution.height),
                    frameRate: context.getTargetFrameRate(),
                    codec: context.getCodec(),
                    displayCount: 1,
                    dimensionToken: dimensionToken,
                    acceptedMediaMaxPacketSize: context.getMediaMaxPacketSize()
                )
                if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
                    MirageLogger.error(.host, "Failed to encode desktopStreamStarted update for stream \(streamID)")
                }
            }

            return
        }

        guard let session = activeSessionByStreamID[streamID] else { return }
        guard let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) else { return }

        let message = await StreamStartedMessage(
            streamID: streamID,
            windowID: session.window.id,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: context.getTargetFrameRate(),
            codec: context.getCodec(),
            minWidth: nil,
            minHeight: nil,
            dimensionToken: dimensionToken,
            acceptedMediaMaxPacketSize: context.getMediaMaxPacketSize()
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
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID)
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
                try ensureDesktopResizeTransactionCanContinue(streamID: streamID)
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
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID)
            await desktopContext.suspendEncodingForDesktopResize()
            shouldResumeEncodingAfterResize = true

            if mirroringPlan == .suspendAndRestore, let displayID = preResizeSnapshot?.displayID {
                await suspendDisplayMirroringForResize(targetDisplayID: displayID)
                suspendedMirroringDisplayID = displayID
                shouldRestoreMirroring = true
            }
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID)

            try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                for: .desktopStream,
                newResolution: pixelResolution,
                refreshRate: streamRefreshRate
            )

            try ensureDesktopResizeTransactionCanContinue(streamID: streamID)

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
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID)
            guard let latestDesktopContext = desktopStreamContext else {
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
            await logDesktopResizeColorPipelineValidation(
                streamID: streamID,
                displaySnapshot: postResizeSnapshot,
                context: latestDesktopContext
            )

            let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
            let inputBounds = resolvedDesktopInputBounds(
                physicalBounds: primaryBounds,
                virtualResolution: effectivePixelResolution
            )
            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: inputBounds)
            if mirroringPlan == .unchanged,
               !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
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
            return
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
                } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                    await disableDisplayMirroring(displayID: restoreDisplayID)
                }
            }
        }

        if shouldStopDesktopStreamWithError, streamID == desktopStreamID {
            shouldResumeEncodingAfterResize = false
            await stopDesktopStream(reason: .error)
            return
        }

        guard desktopResizeTransactionContinuationDecision(
            requestedStreamID: streamID,
            activeDesktopStreamID: desktopStreamID,
            hasDesktopContext: desktopStreamContext != nil
        ) == .continueTransaction else {
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

    private func ensureDesktopResizeTransactionCanContinue(streamID: StreamID) throws {
        let continuationDecision = desktopResizeTransactionContinuationDecision(
            requestedStreamID: streamID,
            activeDesktopStreamID: desktopStreamID,
            hasDesktopContext: desktopStreamContext != nil
        )
        guard continuationDecision == .continueTransaction else {
            throw DesktopResizeTransactionAbort.streamNoLongerActive
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
        let displayResolution = await currentDesktopStartedResolution(
            fallback: CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
        )
        let updatedTargetFrameRate = await context.getTargetFrameRate()
        let codec = await context.getCodec()
        let acceptedMediaMaxPacketSize = await context.getMediaMaxPacketSize()
        let message = DesktopStreamStartedMessage(
            streamID: streamID,
            width: Int(displayResolution.width),
            height: Int(displayResolution.height),
            frameRate: updatedTargetFrameRate,
            codec: codec,
            displayCount: 1,
            dimensionToken: dimensionToken,
            acceptedMediaMaxPacketSize: acceptedMediaMaxPacketSize
        )
        if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            MirageLogger.error(.host, "Failed to encode desktop resize completion for stream \(streamID)")
            return
        }
        let suffix = noOp ? ", no-op" : ""
        MirageLogger.host("Sent desktop resize completion for stream \(streamID) (request #\(requestNumber)\(suffix))")
    }

    private func logDesktopResizeColorPipelineValidation(
        streamID: StreamID,
        displaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        context: StreamContext
    )
    async {
        let settings = await context.getEncoderSettings()
        let runtime = await context.getEncoderRuntimeValidationSnapshot()

        let colorValidation = CGVirtualDisplayBridge.displayColorSpaceValidation(
            displayID: displaySnapshot.displayID,
            expectedColorSpace: settings.colorSpace
        )
        let displayCoverageStatus = colorValidation.coverageStatus
        let displayColorMatches = displayCoverageStatus == .strictCanonical || displayCoverageStatus == .wideGamutEquivalent
        let measuredEquivalentCoverage = displayCoverageStatus == .wideGamutEquivalent
        let displayColorObserved = colorValidation.observedName ?? "unknown"
        let runtimePixelFormat = runtime?.pixelFormat.displayName ?? settings.pixelFormat.displayName
        let runtimeProfile = runtime?.profileName ?? "unknown"
        let runtimePrimaries = runtime?.colorPrimaries ?? "unknown"
        let runtimeTransfer = runtime?.transferFunction ?? "unknown"
        let runtimeMatrix = runtime?.yCbCrMatrix ?? "unknown"
        let runtimeDisplayP3Validated = runtime?.tenBitDisplayP3Validated == true || runtime?.ultra444Validated == true
        let expectsTenBitDisplayP3 = settings.bitDepth == .tenBit && settings.colorSpace == .displayP3
        let displayColorStatus = displayCoverageStatus.rawValue

        if expectsTenBitDisplayP3, displayColorMatches, runtimeDisplayP3Validated {
            let coverageLabel = measuredEquivalentCoverage ? "measured-equivalent" : "canonical"
            MirageLogger.host(
                "Desktop resize validation passed for stream \(streamID): display=\(displaySnapshot.displayID) color=\(displayColorObserved), encoder=\(runtimePixelFormat), profile=\(runtimeProfile), target=Display P3 10-bit (\(coverageLabel))"
            )
            return
        }

        let message =
            "Desktop resize validation status=\(displayColorStatus) for stream \(streamID): " +
            "display=\(displaySnapshot.displayID), expectedColor=\(settings.colorSpace.displayName), observedColor=\(displayColorObserved), " +
            "encoderPixelFormat=\(runtimePixelFormat), encoderProfile=\(runtimeProfile), " +
            "encoderPrimaries=\(runtimePrimaries), encoderTransfer=\(runtimeTransfer), encoderMatrix=\(runtimeMatrix), " +
            "tenBitDisplayP3Validated=\(runtimeDisplayP3Validated)"

        if expectsTenBitDisplayP3 {
            MirageLogger.error(.host, message)
        } else {
            MirageLogger.host(message)
        }
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
        let currentEncodedDimensions = await context.getEncodedDimensions()
        let currentEncodedResolution = CGSize(
            width: currentEncodedDimensions.width,
            height: currentEncodedDimensions.height
        )
        let requestedStreamScale = await context.requestedStreamScale
        let encoderMaxWidth = await context.encoderMaxWidth
        let encoderMaxHeight = await context.encoderMaxHeight
        let disableResolutionCap = context.disableResolutionCap
        let requestedEncodedResolution = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: pixelResolution,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth ?? Int(StreamContext.maxEncodedWidth),
            encoderMaxHeight: encoderMaxHeight ?? Int(StreamContext.maxEncodedHeight),
            disableResolutionCap: disableResolutionCap
        ).encodedPixelSize
        if windowResizeNoOpDecision(
            currentVisibleResolution: currentVisibleResolution,
            currentDisplayResolution: currentDisplayResolution,
            currentEncodedResolution: currentEncodedResolution,
            requestedVisibleResolution: pixelResolution,
            requestedEncodedResolution: requestedEncodedResolution
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
            try await context.updateWindowCaptureResolution(newLogicalSize: logicalResolution)
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
        let acceptedMediaMaxPacketSize = await context.getMediaMaxPacketSize()
        let message = StreamStartedMessage(
            streamID: streamID,
            windowID: updatedWindow.id,
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            frameRate: frameRate,
            codec: codec,
            minWidth: minWidth,
            minHeight: minHeight,
            dimensionToken: dimensionToken,
            acceptedMediaMaxPacketSize: acceptedMediaMaxPacketSize
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
            let driftTolerancePixels: CGFloat = 8
            let driftSampleMatchTolerance: CGFloat = 8
            let stableDriftSampleThreshold = 3

            while !Task.isCancelled {
                guard let state = getVirtualDisplayState(streamID: streamID) else { break }
                guard let windowID = activeWindowIDByStreamID[streamID] else { break }

                if windowResizeInFlightStreamIDs.contains(streamID) {
                    if windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID) != nil {
                        MirageLogger.host(
                            "event=visible_frame_drift_stability state=reset stream=\(streamID) reason=resize_in_flight"
                        )
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        break
                    }
                    continue
                }

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
                    let existingDriftState = windowVisibleFrameDriftStateByStreamID[streamID]
                    let sameCandidateAsPrevious: Bool = if let existingDriftState {
                        abs(existingDriftState.candidateBounds.minX - visibleBounds.minX) <= driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.minY - visibleBounds.minY) <=
                            driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.width - visibleBounds.width) <=
                            driftSampleMatchTolerance &&
                            abs(existingDriftState.candidateBounds.height - visibleBounds.height) <=
                            driftSampleMatchTolerance &&
                            abs(
                                existingDriftState.candidateVisiblePixelResolution.width - currentVisiblePixels.width
                            ) <= driftSampleMatchTolerance &&
                            abs(
                                existingDriftState.candidateVisiblePixelResolution.height - currentVisiblePixels.height
                            ) <= driftSampleMatchTolerance
                    } else {
                        false
                    }
                    let nextSampleCount = sameCandidateAsPrevious
                        ? (existingDriftState?.consecutiveSamples ?? 0) + 1
                        : 1
                    windowVisibleFrameDriftStateByStreamID[streamID] = WindowVisibleFrameDriftState(
                        candidateBounds: visibleBounds,
                        candidateVisiblePixelResolution: currentVisiblePixels,
                        consecutiveSamples: nextSampleCount
                    )
                    MirageLogger.host(
                        "event=visible_frame_drift_stability state=candidate stream=\(streamID) " +
                            "samples=\(nextSampleCount)/\(stableDriftSampleThreshold) " +
                            "cached=\(Int(state.visiblePixelResolution.width))x\(Int(state.visiblePixelResolution.height)) " +
                            "candidate=\(Int(currentVisiblePixels.width))x\(Int(currentVisiblePixels.height))"
                    )
                    if nextSampleCount >= stableDriftSampleThreshold {
                        MirageLogger.host(
                            "event=visible_frame_drift_stability state=stable stream=\(streamID) " +
                                "samples=\(nextSampleCount)"
                        )
                        if let currentState = getVirtualDisplayState(windowID: windowID), currentState.streamID == streamID {
                            let updatedBounds = aspectFittedWindowBounds(
                                visibleBounds,
                                targetAspectRatio: currentState.targetContentAspectRatio
                            )
                            let updatedState = WindowVirtualDisplayState(
                                streamID: currentState.streamID,
                                displayID: currentState.displayID,
                                generation: currentState.generation,
                                bounds: updatedBounds,
                                targetContentAspectRatio: currentState.targetContentAspectRatio,
                                captureSourceRect: currentState.captureSourceRect,
                                visiblePixelResolution: currentVisiblePixels,
                                scaleFactor: currentState.scaleFactor,
                                pixelResolution: currentState.pixelResolution,
                                clientScaleFactor: currentState.clientScaleFactor
                            )
                            setVirtualDisplayState(windowID: windowID, state: updatedState)
                            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: updatedBounds)
                        }
                        windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
                        await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID, force: true)
                    }
                } else if windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID) != nil {
                    MirageLogger.host(
                        "event=visible_frame_drift_stability state=reset stream=\(streamID) reason=drift_cleared"
                    )
                }

                await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)

                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    break
                }
            }
            windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
            windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
        }
    }

    func stopWindowVisibleFrameMonitor(streamID: StreamID) {
        windowVisibleFrameMonitorTasks[streamID]?.cancel()
        windowVisibleFrameMonitorTasks.removeValue(forKey: streamID)
        windowVisibleFrameDriftStateByStreamID.removeValue(forKey: streamID)
    }

    /// Handle display resolution change from client
    func handleDisplayResolutionChange(streamID: StreamID, newResolution: CGSize) async {
        if streamID == desktopStreamID {
            if desktopUsesHostResolution {
                MirageLogger.host(
                    "Ignoring display resolution change for host-resolution desktop stream \(streamID): " +
                        "\(Int(newResolution.width))x\(Int(newResolution.height)) pts"
                )
                return
            }
            await enqueueDesktopResolutionChange(streamID: streamID, logicalResolution: newResolution)
            return
        }

        if let appSession = await appStreamManager.getSessionForStreamID(streamID),
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

        guard streamsByID[streamID] != nil else {
            MirageLogger.debug(.host, "No stream found for display resolution change: \(streamID)")
            return
        }
        await enqueueWindowResolutionChange(streamID: streamID, logicalResolution: newResolution)
    }
}

#endif
