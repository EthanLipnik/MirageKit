//
//  MirageHostService+Streams.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream lifecycle management.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

enum WindowStreamStartFailureCode: Int, Sendable, Equatable, Hashable, Comparable {
    case unknown = 0
    case virtualDisplayCreationFailed = 1
    case virtualDisplayUnavailable = 2
    case virtualDisplayDirectFallbackFailed = 3
    case windowPlacementFailed = 4
    case windowOwnerConflict = 5
    case windowOwnerMismatch = 6
    case windowAlreadyBound = 7
    case windowNotFound = 8
    case noSavedWindowState = 9
    case operationTimedOut = 10
    case runtimeConditionBlocked = 11

    static func < (lhs: WindowStreamStartFailureCode, rhs: WindowStreamStartFailureCode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isOwnershipConflict: Bool {
        self == .windowOwnerConflict || self == .windowOwnerMismatch || self == .windowAlreadyBound
    }

    var isNonRetryableVirtualDisplayAllocationFailure: Bool {
        self == .virtualDisplayCreationFailed || self == .virtualDisplayUnavailable
    }
}

enum WindowStreamStartError: Error {
    case virtualDisplayStartFailed(code: WindowStreamStartFailureCode, details: String)
    case windowAlreadyBound(windowID: WindowID, existingStreamID: StreamID)
}

struct WindowPlacementRepairBackoffStep: Equatable {
    let failureCount: Int
    let retryDelaySeconds: CFAbsoluteTime?
}

func windowPlacementRepairBackoffStep(
    currentFailureCount: Int,
    didSucceed: Bool
)
-> WindowPlacementRepairBackoffStep {
    if didSucceed {
        return WindowPlacementRepairBackoffStep(
            failureCount: 0,
            retryDelaySeconds: nil
        )
    }

    let nextFailureCount = max(0, currentFailureCount) + 1
    let retryScheduleSeconds: [CFAbsoluteTime] = [0.5, 1.0, 2.0, 4.0]
    let retryIndex = min(nextFailureCount - 1, retryScheduleSeconds.count - 1)
    return WindowPlacementRepairBackoffStep(
        failureCount: nextFailureCount,
        retryDelaySeconds: retryScheduleSeconds[retryIndex]
    )
}

extension WindowStreamStartError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .virtualDisplayStartFailed(_, details):
            "Dedicated virtual display start failed: \(details)"
        case let .windowAlreadyBound(windowID, existingStreamID):
            "Window \(windowID) is already streamed by stream \(existingStreamID)"
        }
    }
}

func windowStreamStartFailureCode(for error: Error) -> WindowStreamStartFailureCode {
    if let windowStartError = error as? WindowStreamStartError {
        switch windowStartError {
        case let .virtualDisplayStartFailed(code, _):
            return code
        case .windowAlreadyBound:
            return .windowAlreadyBound
        }
    }

    if let windowSpaceError = error as? WindowSpaceManager.WindowSpaceError {
        switch windowSpaceError {
        case .moveFailed:
            return .windowPlacementFailed
        case .ownerConflict:
            return .windowOwnerConflict
        case .ownerMismatch:
            return .windowOwnerMismatch
        case .windowNotFound:
            return .windowNotFound
        case .noOriginalState:
            return .noSavedWindowState
        }
    }

    if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
        switch sharedDisplayError {
        case .creationFailed:
            return .virtualDisplayCreationFailed
        case .apiNotAvailable, .noActiveDisplay, .streamDisplayNotFound, .spaceNotFound, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound:
            return .virtualDisplayUnavailable
        }
    }

    if let nsError = error as NSError?,
       nsError.domain == "CoreGraphicsErrorDomain",
       nsError.code == 1003 {
        // Dedicated virtual-display startup can race the display graph even when direct
        // window capture remains viable. Treat this as recoverable so the host degrades.
        return .windowPlacementFailed
    }

    if error is MirageRuntimeConditionError {
        return .runtimeConditionBlocked
    }

    if let mirageError = error as? MirageError {
        switch mirageError {
        case .windowNotFound:
            return .windowNotFound
        case .timeout:
            return .operationTimedOut
        case let .protocolError(message):
            if message.contains("Unable to resolve SCWindow") || message.contains("Unable to resolve SCDisplay") {
                return .windowNotFound
            }
            return .unknown
        default:
            return .unknown
        }
    }

    return .unknown
}

func windowStreamStartShouldFallbackToDirectCapture(for error: Error) -> Bool {
    let failureCode = windowStreamStartFailureCode(for: error)
    if let windowStartError = error as? WindowStreamStartError {
        switch windowStartError {
        case .virtualDisplayStartFailed:
            return !failureCode.isOwnershipConflict
        case .windowAlreadyBound:
            return false
        }
    }

    switch failureCode {
    case .virtualDisplayCreationFailed,
         .virtualDisplayUnavailable,
         .windowPlacementFailed,
         .windowNotFound,
         .operationTimedOut:
        return true
    case .virtualDisplayDirectFallbackFailed,
         .windowOwnerConflict,
         .windowOwnerMismatch,
         .windowAlreadyBound,
         .noSavedWindowState,
         .runtimeConditionBlocked,
         .unknown:
        return false
    }
}

@MainActor
public extension MirageHostService {
    @discardableResult
    func startStream(
        for window: MirageWindow,
        to client: MirageConnectedClient,
        clientDisplayResolution: CGSize? = nil,
        clientScaleFactor: CGFloat? = nil,
        keyFrameInterval: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        performanceMode: MirageStreamPerformanceMode = .standard,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool = true,
        temporaryDegradationMode: MirageTemporaryDegradationMode = .off,
        disableResolutionCap: Bool = false,
        allowBestEffortRemap: Bool = true,
        allowDirectCaptureFallback: Bool = false,
        audioConfiguration: MirageAudioConfiguration? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil,
        sizePreset: MirageDisplaySizePreset = .standard
    )
    async throws -> MirageStreamSession {
        // Clear any stuck modifier state from previous streams
        inputController.clearAllModifiers()

        guard !disconnectingClientIDs.contains(client.id),
              clientsByID[client.id] != nil else {
            throw MirageError.protocolError("Client is disconnected or disconnecting")
        }

        // Resolve capture sources from live ScreenCaptureKit content to avoid stale host window IDs.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let disallowedWindowIDs = Set(activeStreamIDByWindowID.keys)
        let captureSource = try resolveCaptureSource(
            for: window,
            from: content,
            disallowedWindowIDs: disallowedWindowIDs,
            allowFallbackRemap: allowBestEffortRemap
        )
        let scWindow = captureSource.window
        let scApplication = captureSource.application
        let resolvedWindowID = WindowID(scWindow.windowID)
        if let existingStreamID = activeStreamIDByWindowID[resolvedWindowID] {
            throw WindowStreamStartError.windowAlreadyBound(
                windowID: resolvedWindowID,
                existingStreamID: existingStreamID
            )
        }
        if resolvedWindowID != window.id {
            MirageLogger.host("Resolved window \(window.id) to live window \(resolvedWindowID) for stream start")
        }

        guard let clientDisplayResolution,
              clientDisplayResolution.width > 0,
              clientDisplayResolution.height > 0 else {
            throw MirageError.protocolError("App/window streaming requires a client display resolution")
        }

        let streamID = nextStreamID
        nextStreamID += 1

        let resolvedWindowApplication = MirageApplication(
            id: scApplication.processID,
            bundleIdentifier: scApplication.bundleIdentifier,
            name: scApplication.applicationName
        )
        let resolvedWindowFrame = scWindow.frame
        let latestFrame = currentWindowFrame(for: resolvedWindowID) ?? resolvedWindowFrame
        let updatedWindow = MirageWindow(
            id: resolvedWindowID,
            title: scWindow.title ?? window.title,
            application: resolvedWindowApplication,
            frame: latestFrame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: scWindow.windowLayer
        )

        var session = MirageStreamSession(
            id: streamID,
            window: updatedWindow,
            client: client
        )

        let effectiveEncoderConfig = resolveEncoderConfiguration(
            keyFrameInterval: keyFrameInterval,
            targetFrameRate: targetFrameRate,
            colorDepth: colorDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate,
            upscalingMode: upscalingMode,
            codec: codec
        )
        guard mediaSecurityByClientID[client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for client")
        }

        guard !disconnectingClientIDs.contains(client.id),
              clientsByID[client.id] != nil else {
            throw MirageError.protocolError("Client is disconnected or disconnecting")
        }

        // Create stream context with capture and encoding
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = if performanceMode == .game {
            .tuned
        } else {
            .baseline
        }
        let resolvedAudioConfiguration = audioConfiguration ?? .default
        let context = StreamContext(
            streamID: streamID,
            windowID: updatedWindow.id,
            streamKind: .window,
            encoderConfig: effectiveEncoderConfig,
            streamScale: streamScale ?? 1.0,
            requestedAudioChannelCount: resolvedAudioConfiguration.channelLayout.channelCount,
            maxPacketSize: networkConfig.maxPacketSize,
            mediaSecurityContext: nil,
            runtimeQualityAdjustmentEnabled: allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoost,
            temporaryDegradationMode: temporaryDegradationMode,
            disableResolutionCap: disableResolutionCap,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
        if disableResolutionCap {
            MirageLogger.host("Resolution cap disabled for stream \(streamID)")
        }
        MirageLogger.host("Performance mode for stream \(streamID): \(performanceMode.displayName)")
        if performanceMode != .game {
            MirageLogger.host("Latency mode for stream \(streamID): \(latencyMode.displayName)")
        }
        if performanceMode != .game, allowRuntimeQualityAdjustment == false {
            MirageLogger.host("Runtime quality adjustment disabled for stream \(streamID)")
        }
        if performanceMode != .game, !lowLatencyHighResolutionCompressionBoost {
            MirageLogger.host("Low-latency high-res compression boost disabled for stream \(streamID)")
        }
        // Reserve stream/window ownership before the first await after binding resolution.
        // This closes a startup race where concurrent starts could otherwise bind the same
        // resolved live window before either stream reached registration.
        streamsByID[streamID] = context
        registerTypingBurstRoute(streamID: streamID, context: context)
        await registerStallWindowPointerRoute(streamID: streamID, context: context)
        registerActiveStreamSession(session)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.dispatchControlWork(clientID: client.id) { [weak self] in
                guard let self else { return }
                guard let clientContext = findClientContext(clientID: client.id) else { return }
                do {
                    try await clientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Stream metrics"
                    )
                }
            }
        }

        await activateAudioForClient(
            clientID: client.id,
            sourceStreamID: streamID,
            configuration: resolvedAudioConfiguration
        )

        // Enable power assertion to prevent display sleep during streaming
        await PowerAssertionManager.shared.enable()

        // Update input cache for fast input routing (thread-safe)
        inputStreamCacheActor.set(streamID, window: updatedWindow, client: client)

        // Open Loom video stream for this stream
        if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == client.id }) {
            do {
                let videoStream = try await clientContext.controlChannel.session.openStream(
                    label: "video/\(streamID)"
                )
                loomVideoStreamsByStreamID[streamID] = videoStream
                transportRegistry.registerVideoStream(videoStream, streamID: streamID)
                MirageLogger.host("Opened Loom video stream for stream \(streamID)")
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to open Loom video stream for stream \(streamID): "
                )
            }
        }

        // Wrap ScreenCaptureKit types for safe sending across actor boundary
        let windowWrapper = SCWindowWrapper(window: scWindow)
        let applicationWrapper = SCApplicationWrapper(application: scApplication)
        let displayWrapper = SCDisplayWrapper(display: captureSource.display)

        // Start capture with callback to send video data
        // This will throw if screen recording permission is not granted
        let onEncodedFrame: @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void = {
            [weak self] packetData, _, releasePacket in
            guard let self else {
                releasePacket()
                return
            }
            sendVideoPacketForStream(streamID, data: packetData) { [weak self] error in
                releasePacket()
                guard let self, let error else { return }
                dispatchMainWork {
                    await self.handleVideoSendError(streamID: streamID, error: error)
                }
            }
        }

        let resolvedClientScaleFactor: CGFloat? = if let clientScaleFactor, clientScaleFactor > 0 {
            max(1.0, clientScaleFactor)
        } else {
            nil
        }
        let virtualDisplayResolution = virtualDisplayPixelResolution(
            for: clientDisplayResolution,
            client: client,
            scaleFactorOverride: resolvedClientScaleFactor
        )
        var hasAttemptedStaleOwnerRecovery = false

        virtualDisplayStartupLoop: while true {
            do {
                await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded()
                MirageLogger
                    .host(
                        "Starting stream with virtual display at " +
                            "\(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height)) pts " +
                            "(\(Int(virtualDisplayResolution.width))x\(Int(virtualDisplayResolution.height)) px)"
                    )

                try await context.startWithWindowCapture(
                    windowWrapper: windowWrapper,
                    applicationWrapper: applicationWrapper,
                    clientLogicalSize: clientDisplayResolution,
                    sizePreset: sizePreset,
                    onEncodedFrame: onEncodedFrame,
                    onContentBoundsChanged: { [weak self] bounds in
                        guard let self else { return }
                        dispatchControlWork(clientID: client.id) { [weak self] in
                            guard let self else { return }
                            await sendContentBoundsUpdate(streamID: streamID, bounds: bounds, to: client)
                        }
                    },
                    onNewWindowDetected: { [weak self] newWindow in
                        guard let self else { return }
                        dispatchControlWork(clientID: client.id) { [weak self] in
                            guard let self else { return }
                            await handleNewIndependentWindow(
                                newWindow,
                                originalStreamID: streamID,
                                client: client
                            )
                        }
                    }
                )

                if let bounds = getVirtualDisplayBounds(windowID: updatedWindow.id) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: bounds)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(bounds)")
                } else if let newFrame = currentWindowFrame(for: updatedWindow.id) {
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                    MirageLogger.host("Updated input cache with new frame after virtual display move: \(newFrame)")
                }

                let resolvedStreamFrame = getVirtualDisplayBounds(windowID: updatedWindow.id)
                    ?? currentWindowFrame(for: updatedWindow.id)
                    ?? updatedWindow.frame
                let resolvedWindow = MirageWindow(
                    id: updatedWindow.id,
                    title: updatedWindow.title,
                    application: updatedWindow.application,
                    frame: resolvedStreamFrame,
                    isOnScreen: updatedWindow.isOnScreen,
                    windowLayer: updatedWindow.windowLayer
                )
                session = MirageStreamSession(
                    id: streamID,
                    window: resolvedWindow,
                    client: client
                )
                registerActiveStreamSession(session)
                inputStreamCacheActor.updateWindowFrame(streamID, newFrame: resolvedWindow.frame)
                await refreshWindowVirtualDisplayState(
                    streamID: streamID,
                    context: context,
                    clientScaleFactorOverride: resolvedClientScaleFactor
                )
                ensureWindowVisibleFrameMonitor(streamID: streamID)
                break virtualDisplayStartupLoop
            } catch let virtualDisplayError {
                let activeOtherStreamIDs = Set(activeSessionByStreamID.keys).subtracting([streamID])
                let failureCode = classifyWindowStreamStartFailure(virtualDisplayError)
                if failureCode.isOwnershipConflict {
                    if let conflictingOwnerStreamID = conflictingOwnerStreamID(from: virtualDisplayError),
                       activeOtherStreamIDs.contains(conflictingOwnerStreamID) {
                        await cleanupFailedStreamStart(
                            streamID: streamID,
                            context: context,
                            windowID: updatedWindow.id
                        )
                        throw WindowStreamStartError.windowAlreadyBound(
                            windowID: updatedWindow.id,
                            existingStreamID: conflictingOwnerStreamID
                        )
                    }

                    if !hasAttemptedStaleOwnerRecovery {
                        let recoveryResult = await WindowSpaceManager.shared.attemptStaleOwnerRecovery(
                            for: updatedWindow.id,
                            activeStreamIDs: activeOtherStreamIDs
                        )
                        switch recoveryResult {
                        case let .activeOwnerConflict(ownerStreamID):
                            await cleanupFailedStreamStart(
                                streamID: streamID,
                                context: context,
                                windowID: updatedWindow.id
                            )
                            throw WindowStreamStartError.windowAlreadyBound(
                                windowID: updatedWindow.id,
                                existingStreamID: ownerStreamID
                            )
                        case .staleOwnerRestoreSuccess, .staleOwnerClearedAfterRestoreFailure:
                            hasAttemptedStaleOwnerRecovery = true
                            await context.stop()
                            clearVirtualDisplayState(windowID: updatedWindow.id)
                            continue virtualDisplayStartupLoop
                        case .noSavedState, .noOwner:
                            break
                        }
                    }
                }

                let detail = virtualDisplayError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedDetail = detail.isEmpty ? String(describing: virtualDisplayError) : detail
                let allowOwnerFallbackAfterRecovery = hasAttemptedStaleOwnerRecovery &&
                    failureCode.isOwnershipConflict &&
                    {
                        guard let conflictingOwnerStreamID = conflictingOwnerStreamID(from: virtualDisplayError) else {
                            return false
                        }
                        return !activeOtherStreamIDs.contains(conflictingOwnerStreamID)
                    }()

                if allowDirectCaptureFallback,
                   shouldFallbackToDirectWindowCapture(virtualDisplayError) || allowOwnerFallbackAfterRecovery {
                    MirageLogger.host(
                        "Virtual-display stream start failed for stream \(streamID) window \(updatedWindow.id); retrying with direct window capture: \(renderedDetail)"
                    )
                    await context.stop()
                    clearVirtualDisplayState(windowID: updatedWindow.id)
                    do {
                        try await context.start(
                            windowWrapper: windowWrapper,
                            applicationWrapper: applicationWrapper,
                            displayWrapper: displayWrapper,
                            onEncodedFrame: onEncodedFrame
                        )
                        if let newFrame = currentWindowFrame(for: updatedWindow.id) {
                            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
                        }
                        MirageLogger.host(
                            "Recovered stream \(streamID) with direct window-capture fallback for window \(updatedWindow.id)"
                        )
                        break virtualDisplayStartupLoop
                    } catch {
                        MirageLogger.error(
                            .host,
                            error: error,
                            message: "Direct window-capture fallback failed after virtual-display startup error: "
                        )
                        await cleanupFailedStreamStart(
                            streamID: streamID,
                            context: context,
                            windowID: updatedWindow.id
                        )
                        let fallbackDetail = error.localizedDescription
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let renderedFallbackDetail = fallbackDetail.isEmpty ? String(describing: error) : fallbackDetail
                        throw WindowStreamStartError.virtualDisplayStartFailed(
                            code: .virtualDisplayDirectFallbackFailed,
                            details: "\(renderedDetail); direct fallback failed: \(renderedFallbackDetail)"
                        )
                    }
                } else {
                    // windowNotFound / noSavedWindowState are expected when
                    // the target window was closed before streaming started.
                    // Log at info level to avoid Sentry noise.
                    if failureCode == .windowNotFound || failureCode == .noSavedWindowState {
                        MirageLogger.host(
                            "Virtual-display stream start skipped (\(failureCode)): \(virtualDisplayError)"
                        )
                    } else {
                        MirageLogger.error(
                            .host,
                            error: virtualDisplayError,
                            message: "Virtual-display stream start failed: "
                        )
                    }
                    await cleanupFailedStreamStart(
                        streamID: streamID,
                        context: context,
                        windowID: updatedWindow.id
                    )
                    throw WindowStreamStartError.virtualDisplayStartFailed(
                        code: failureCode,
                        details: renderedDetail
                    )
                }
            }
        }

        // Dedicated-display streams should avoid implicit activation because AppKit activation
        // can steal host focus and momentarily bounce windows back to physical spaces.
        if isStreamUsingVirtualDisplay(windowID: updatedWindow.id) {
            await enforceVirtualDisplayPlacementAfterActivation(windowID: updatedWindow.id, force: true)
            scheduleVirtualDisplayPlacementReassert(windowID: updatedWindow.id)
        }

        // Only notify client AFTER capture successfully started
        if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == client.id }) {
            let streamWindow = session.window
            let minSize = minimumSizesByWindowID[streamWindow.id]
            let fallbackMin = fallbackMinimumSize(for: streamWindow.frame)
            let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
            let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

            let encodedDimensions = await context.getEncodedDimensions()
            let targetFrameRate = await context.getTargetFrameRate()
            let codec = await context.getCodec()
            let startupAttemptID = UUID()

            // Get dimension token from stream context
            let dimensionToken = await context.getDimensionToken()

            let message = StreamStartedMessage(
                streamID: streamID,
                windowID: streamWindow.id,
                width: encodedDimensions.width,
                height: encodedDimensions.height,
                frameRate: targetFrameRate,
                codec: codec,
                startupAttemptID: startupAttemptID,
                minWidth: minWidth,
                minHeight: minHeight,
                dimensionToken: dimensionToken
            )
            do {
                registerPendingStartupAttempt(
                    streamID: streamID,
                    startupAttemptID: startupAttemptID,
                    clientID: clientContext.client.id,
                    kind: .window
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger.signpostEvent(.host, "Startup.StreamStartedSent", "stream=\(streamID) kind=window")
            } catch {
                cancelPendingStartupAttempt(streamID: streamID)
                throw error
            }
        }

        await markAppStreamInteraction(streamID: streamID, reason: "stream started")

        // Start menu bar monitoring for this stream
        if let app = session.window.application {
            await startMenuBarMonitoring(streamID: streamID, app: app, client: client)
        }

        await updateLightsOutState()
        inputController.beginTrafficLightProtection(
            windowID: session.window.id,
            app: session.window.application,
            usesVirtualDisplay: isStreamUsingVirtualDisplay(windowID: session.window.id)
        )
        MirageInstrumentation.record(.hostStreamWindowStartedPerformanceMode(.init(rawMode: performanceMode.rawValue)))

        return session
    }

    private func resolveEncoderConfiguration(
        keyFrameInterval: Int?,
        targetFrameRate: Int?,
        colorDepth: MirageStreamColorDepth?,
        captureQueueDepth: Int?,
        bitrate: Int?,
        upscalingMode: MirageUpscalingMode? = nil,
        codec: MirageVideoCodec? = nil
    ) -> MirageEncoderConfiguration {
        var effectiveEncoderConfig = encoderConfig
        let requestedColorDepth = colorDepth
        let resolvedColorDepth = effectiveColorDepth(for: requestedColorDepth)

        if keyFrameInterval != nil || resolvedColorDepth != nil || captureQueueDepth != nil || bitrate != nil {
            effectiveEncoderConfig = encoderConfig.withOverrides(
                keyFrameInterval: keyFrameInterval,
                colorDepth: resolvedColorDepth,
                captureQueueDepth: captureQueueDepth,
                bitrate: bitrate
            )
            if let interval = keyFrameInterval { MirageLogger.host("Using client-requested keyframe interval: \(interval) frames") }
            if let requestedColorDepth, let resolvedColorDepth, requestedColorDepth != resolvedColorDepth {
                MirageLogger.host(
                    "Color depth request downgraded: requested=\(requestedColorDepth.displayName), effective=\(resolvedColorDepth.displayName)"
                )
            } else if let resolvedColorDepth {
                MirageLogger.host("Using client-requested color depth: \(resolvedColorDepth.displayName)")
            }
            if let captureQueueDepth { MirageLogger.host("Using client-requested capture queue depth: \(captureQueueDepth)") }
            if let bitrate { MirageLogger.host("Using client-requested bitrate: \(bitrate)") }
        }

        if let codec {
            effectiveEncoderConfig.codec = codec
        }

        // Switch to BGRA pixel format when client requests MetalFX upscaling.
        // MetalFX is incompatible with ProRes pixel formats.
        if let upscalingMode, upscalingMode != .off, codec != .proRes4444 {
            effectiveEncoderConfig.applyUpscalingPixelFormat()
            MirageLogger.host("Applying BGRA pixel format for MetalFX \(upscalingMode.displayName) upscaling")
        }

        if let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(
            bitrate: effectiveEncoderConfig.bitrate
        ) {
            effectiveEncoderConfig.bitrate = normalized
        }

        // Apply target frame rate override if specified (based on P2P + client capability)
        if let targetFrameRate {
            effectiveEncoderConfig = effectiveEncoderConfig.withTargetFrameRate(targetFrameRate)
            MirageLogger.host("Using target frame rate: \(targetFrameRate)fps")
        }

        return effectiveEncoderConfig
    }

    private func classifyWindowStreamStartFailure(_ error: Error) -> WindowStreamStartFailureCode {
        windowStreamStartFailureCode(for: error)
    }

    private func shouldFallbackToDirectWindowCapture(_ error: Error) -> Bool {
        windowStreamStartShouldFallbackToDirectCapture(for: error)
    }

    private func cleanupFailedStreamStart(
        streamID: StreamID,
        context: StreamContext,
        windowID: WindowID
    )
    async {
        await context.stop()
        clearVirtualDisplayState(windowID: windowID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
        windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
        windowResizeInFlightStreamIDs.remove(streamID)
        clearAppStreamGovernorState(streamID: streamID)
        stopWindowVisibleFrameMonitor(streamID: streamID)
        streamsByID.removeValue(forKey: streamID)
        transportSendErrorReported.remove(streamID)
        unregisterTypingBurstRoute(streamID: streamID)
        unregisterStallWindowPointerRoute(streamID: streamID)
        removeActiveStreamSession(streamID: streamID)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await deactivateAudioSourceIfNeeded(streamID: streamID)
        inputStreamCacheActor.remove(streamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            Task { try? await videoStream.close() }
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
    }

    private func conflictingOwnerStreamID(from error: Error) -> StreamID? {
        if let windowStartError = error as? WindowStreamStartError {
            switch windowStartError {
            case let .windowAlreadyBound(_, existingStreamID):
                return existingStreamID
            case .virtualDisplayStartFailed:
                break
            }
        }

        if let windowSpaceError = error as? WindowSpaceManager.WindowSpaceError {
            switch windowSpaceError {
            case let .ownerConflict(_, existingStreamID, _):
                return existingStreamID
            case let .ownerMismatch(_, _, actualStreamID):
                return actualStreamID == 0 ? nil : actualStreamID
            case .windowNotFound, .noOriginalState, .moveFailed:
                return nil
            }
        }

        return nil
    }

    private func virtualDisplayPlacementDriftReason(
        windowID: WindowID,
        expectedSpaceID: CGSSpaceID,
        state: WindowVirtualDisplayState
    ) -> String? {
        let currentSpaceMembership = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
        if !currentSpaceMembership.isEmpty, !currentSpaceMembership.contains(expectedSpaceID) {
            return "space drift expected=\(expectedSpaceID) actual=\(currentSpaceMembership)"
        }

        guard let currentFrame = currentWindowFrame(for: windowID) else { return nil }

        let expectedFrame = aspectFittedWindowBounds(
            state.bounds,
            targetAspectRatio: state.targetContentAspectRatio
        )
        let originTolerance: CGFloat = 8
        let sizeTolerance: CGFloat = 8
        let originMatches = abs(currentFrame.minX - expectedFrame.minX) <= originTolerance &&
            abs(currentFrame.minY - expectedFrame.minY) <= originTolerance
        let sizeMatches = abs(currentFrame.width - expectedFrame.width) <= sizeTolerance &&
            abs(currentFrame.height - expectedFrame.height) <= sizeTolerance
        if originMatches, sizeMatches {
            return nil
        }

        let intersectsExpected = currentFrame.intersects(
            expectedFrame.insetBy(dx: -originTolerance, dy: -originTolerance)
        )
        let minimumExpectedWidth = max(1, expectedFrame.width - sizeTolerance)
        let minimumExpectedHeight = max(1, expectedFrame.height - sizeTolerance)
        let maximumExpectedWidth = expectedFrame.width + sizeTolerance
        let maximumExpectedHeight = expectedFrame.height + sizeTolerance
        let sizeWithinExpectedRange = currentFrame.width >= minimumExpectedWidth &&
            currentFrame.height >= minimumExpectedHeight &&
            currentFrame.width <= maximumExpectedWidth &&
            currentFrame.height <= maximumExpectedHeight
        if intersectsExpected, sizeWithinExpectedRange {
            return nil
        }

        if currentSpaceMembership.contains(expectedSpaceID) {
            let localExpected = CGRect(origin: .zero, size: expectedFrame.size)
                .insetBy(dx: -originTolerance, dy: -originTolerance)
            if currentFrame.intersects(localExpected), sizeWithinExpectedRange {
                return nil
            }
        }

        return "frame drift expected=\(expectedFrame) observed=\(currentFrame)"
    }

    func enforceVirtualDisplayPlacementAfterActivation(
        windowID: WindowID,
        force: Bool = false
    ) async {
        // For window capture, only ensure the window is on the correct space.
        // Do NOT resize or reposition — the window is aspect-fit to the client's
        // resolution and the full moveWindow flow fights that sizing.
        for (_, context) in streamsByID {
            let wID = await context.windowID
            guard wID == windowID else { continue }
            let mode = await context.captureMode
            if mode == .window {
                guard let vdContext = await context.virtualDisplayContext else { return }
                let spaceID = CGVirtualDisplayBridge.getSpaceForDisplay(vdContext.displayID)
                guard spaceID != 0 else { return }
                let currentSpaces = CGSWindowSpaceBridge.getSpacesForWindow(windowID)
                if !currentSpaces.contains(spaceID) {
                    CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
                    MirageLogger.host("Window capture: reasserted window \(windowID) to space \(spaceID)")
                }
                return
            }
            break
        }

        guard let state = getVirtualDisplayState(windowID: windowID) else { return }

        let placementBounds = state.bounds
        let placementAspectRatio = state.targetContentAspectRatio

        let resolvedSpaceID = CGVirtualDisplayBridge.getSpaceForDisplay(state.displayID)
        guard resolvedSpaceID != 0 else {
            MirageLogger.host("Skipping placement reassert for window \(windowID): no active space for display \(state.displayID)")
            return
        }

        let driftReason = force
            ? "forced reassert"
            : virtualDisplayPlacementDriftReason(
                windowID: windowID,
                expectedSpaceID: resolvedSpaceID,
                state: state
            )
        guard force || driftReason != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if !force,
           let backoffState = windowPlacementRepairBackoffByWindowID[windowID],
           now < backoffState.nextRetryAt {
            return
        }

        let cooldown: CFAbsoluteTime = 0.20
        if !force,
           let lastAppliedAt = lastWindowPlacementRepairAtByWindowID[windowID],
           now - lastAppliedAt < cooldown {
            return
        }
        lastWindowPlacementRepairAtByWindowID[windowID] = now

        do {
            try await WindowSpaceManager.shared.moveWindow(
                windowID,
                toSpaceID: resolvedSpaceID,
                displayID: state.displayID,
                displayBounds: placementBounds,
                targetContentAspectRatio: placementAspectRatio,
                owner: WindowSpaceManager.WindowBindingOwner(
                    streamID: state.streamID,
                    windowID: windowID,
                    displayID: state.displayID,
                    generation: state.generation
                )
            )
            inputStreamCacheActor.updateWindowFrame(state.streamID, newFrame: placementBounds)
            let reasonText = driftReason ?? "placement drift"
            MirageLogger.host(
                "Reasserted virtual-display placement for window \(windowID) on display \(state.displayID) (\(reasonText))"
            )
            if let previousBackoff = windowPlacementRepairBackoffByWindowID.removeValue(forKey: windowID) {
                let resetStep = windowPlacementRepairBackoffStep(
                    currentFailureCount: previousBackoff.failureCount,
                    didSucceed: true
                )
                MirageLogger.host(
                    "event=placement_repair_backoff reset_on_success=true " +
                        "previous_failure_count=\(previousBackoff.failureCount) " +
                        "failure_count=\(resetStep.failureCount) window=\(windowID) stream=\(state.streamID)"
                )
            }
        } catch {
            if !force {
                let currentFailureCount = windowPlacementRepairBackoffByWindowID[windowID]?.failureCount ?? 0
                let nextStep = windowPlacementRepairBackoffStep(
                    currentFailureCount: currentFailureCount,
                    didSucceed: false
                )
                if let retryDelaySeconds = nextStep.retryDelaySeconds {
                    windowPlacementRepairBackoffByWindowID[windowID] = WindowPlacementRepairBackoffState(
                        failureCount: nextStep.failureCount,
                        nextRetryAt: now + retryDelaySeconds
                    )
                    let nextRetryMilliseconds = Int((retryDelaySeconds * 1000).rounded())
                    MirageLogger.host(
                        "event=placement_repair_backoff failure_count=\(nextStep.failureCount) " +
                            "next_retry_ms=\(nextRetryMilliseconds) window=\(windowID) stream=\(state.streamID)"
                    )
                }
            }
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to reassert virtual-display placement for window \(windowID): "
            )
        }
    }

    private func scheduleVirtualDisplayPlacementReassert(windowID: WindowID) {
        let retryDelays: [Duration] = [
            .milliseconds(120),
            .milliseconds(260),
            .milliseconds(520),
        ]

        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in retryDelays {
                try? await Task.sleep(for: delay)
                guard isStreamUsingVirtualDisplay(windowID: windowID) else { return }
                await enforceVirtualDisplayPlacementAfterActivation(windowID: windowID)
            }
        }
    }

    private struct StreamCaptureSource {
        let window: SCWindow
        let application: SCRunningApplication
        let display: SCDisplay
    }

    private func resolveCaptureSource(
        for requestedWindow: MirageWindow,
        from content: SCShareableContent,
        disallowedWindowIDs: Set<WindowID> = [],
        allowFallbackRemap: Bool = true
    ) throws -> StreamCaptureSource {
        if let directWindow = content.windows.first(where: { $0.windowID == requestedWindow.id }),
           !disallowedWindowIDs.contains(WindowID(directWindow.windowID)),
           let directApp = directWindow.owningApplication,
           let directDisplay = resolveDisplayForCaptureWindow(directWindow, displays: content.displays) {
            return StreamCaptureSource(window: directWindow, application: directApp, display: directDisplay)
        }

        guard allowFallbackRemap else {
            throw MirageError.windowNotFound
        }

        let requestedBundleID = requestedWindow.application?.bundleIdentifier?.lowercased()
        let requestedPID = requestedWindow.application?.id
        let fallbackCandidates = content.windows
            .filter { candidate in
                if disallowedWindowIDs.contains(WindowID(candidate.windowID)) {
                    return false
                }
                guard let candidateApp = candidate.owningApplication else { return false }
                if let requestedPID, candidateApp.processID == requestedPID { return true }
                guard let requestedBundleID else { return false }
                return candidateApp.bundleIdentifier.lowercased() == requestedBundleID
            }
            .sorted { lhs, rhs in
                captureCandidateScore(lhs, requestedWindow: requestedWindow) <
                    captureCandidateScore(rhs, requestedWindow: requestedWindow)
            }

        for candidate in fallbackCandidates {
            guard let candidateApp = candidate.owningApplication,
                  let candidateDisplay = resolveDisplayForCaptureWindow(candidate, displays: content.displays) else {
                continue
            }
            return StreamCaptureSource(window: candidate, application: candidateApp, display: candidateDisplay)
        }

        throw MirageError.windowNotFound
    }

    private func resolveDisplayForCaptureWindow(_ window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return containingDisplay
        }

        var bestIntersectionArea: CGFloat = 0
        var bestDisplay: SCDisplay?
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }
        if let bestDisplay { return bestDisplay }

        return displays.first
    }

    private func captureCandidateScore(
        _ candidate: SCWindow,
        requestedWindow: MirageWindow
    ) -> Int {
        var score = 0

        if !candidate.isOnScreen {
            score += 1_000_000
        }

        // Keep standard app windows ahead of utility/overlay layers.
        if candidate.windowLayer != 0 {
            score += 2_000
        }
        score += abs(candidate.windowLayer - requestedWindow.windowLayer) * 250

        let requestedTitle = (requestedWindow.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateTitle = (candidate.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !requestedTitle.isEmpty {
            if candidateTitle == requestedTitle {
                score += 0
            } else if candidateTitle.contains(requestedTitle) || requestedTitle.contains(candidateTitle) {
                score += 150
            } else {
                score += 600
            }
        }

        let requestedFrame = requestedWindow.frame
        let candidateFrame = candidate.frame
        let sizeDelta = abs(candidateFrame.width - requestedFrame.width) +
            abs(candidateFrame.height - requestedFrame.height)
        let originDelta = abs(candidateFrame.minX - requestedFrame.minX) +
            abs(candidateFrame.minY - requestedFrame.minY)
        score += Int(sizeDelta)
        score += Int(originDelta * 0.25)

        if candidateFrame.width < 160 || candidateFrame.height < 120 {
            score += 10_000
        }

        return score
    }

    func registerActiveStreamSession(_ session: MirageStreamSession) {
        if let previousSession = activeSessionByStreamID[session.id],
           previousSession.window.id != session.window.id,
           activeStreamIDByWindowID[previousSession.window.id] == session.id {
            activeStreamIDByWindowID.removeValue(forKey: previousSession.window.id)
        }

        activeSessionByStreamID[session.id] = session
        activeWindowIDByStreamID[session.id] = session.window.id
        activeStreamIDByWindowID[session.window.id] = session.id

        if let index = activeStreams.firstIndex(where: { $0.id == session.id }) {
            activeStreams[index] = session
        } else {
            activeStreams.append(session)
        }

        syncSharedClipboardState(reason: "app_stream_registered")
    }

    func removeActiveStreamSession(streamID: StreamID) {
        let removedSession = activeSessionByStreamID.removeValue(forKey: streamID)
        activeStreams.removeAll { $0.id == streamID }

        if let removedSession,
           activeStreamIDByWindowID[removedSession.window.id] == streamID {
            activeStreamIDByWindowID.removeValue(forKey: removedSession.window.id)
            lastWindowPlacementRepairAtByWindowID.removeValue(forKey: removedSession.window.id)
            windowPlacementRepairBackoffByWindowID.removeValue(forKey: removedSession.window.id)
        }

        if let mappedWindowID = activeWindowIDByStreamID.removeValue(forKey: streamID),
           activeStreamIDByWindowID[mappedWindowID] == streamID {
            activeStreamIDByWindowID.removeValue(forKey: mappedWindowID)
            lastWindowPlacementRepairAtByWindowID.removeValue(forKey: mappedWindowID)
            windowPlacementRepairBackoffByWindowID.removeValue(forKey: mappedWindowID)
        }

        syncSharedClipboardState(reason: "app_stream_removed")
    }

    func stopStream(
        _ session: MirageStreamSession,
        minimizeWindow: Bool = false,
        updateAppSession: Bool = true
    )
    async {
        clearPendingAppWindowReplacement(streamID: session.id)
        cancelPendingStartupAttempt(streamID: session.id)
        guard let context = streamsByID[session.id] else { return }

        // Clear any stuck modifier state when stream ends
        inputController.clearAllModifiers()

        // Stop menu bar monitoring for this stream
        await stopMenuBarMonitoring(streamID: session.id)

        // Capture window ID before cleanup for minimize
        let windowID = session.window.id
        let appSessionForStoppedWindow: MirageAppStreamSession? = if updateAppSession {
            await appStreamManager.getSessionForWindow(windowID)
        } else {
            nil
        }

        // Remove dedicated virtual display state for this window.
        clearVirtualDisplayState(windowID: windowID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: session.id)
        windowResizeRequestCounterByStreamID.removeValue(forKey: session.id)
        windowResizeInFlightStreamIDs.remove(session.id)
        clearAppStreamGovernorState(streamID: session.id)
        stopWindowVisibleFrameMonitor(streamID: session.id)

        await context.stop()
        inputController.endTrafficLightProtection(windowID: windowID)
        streamsByID.removeValue(forKey: session.id)
        unregisterTypingBurstRoute(streamID: session.id)
        unregisterStallWindowPointerRoute(streamID: session.id)
        removeActiveStreamSession(streamID: session.id)
        await syncAppListRequestDeferralForInteractiveWorkload()
        await deactivateAudioSourceIfNeeded(streamID: session.id)

        // Remove from input cache (thread-safe)
        inputStreamCacheActor.remove(session.id)

        // Clean up Loom video stream for this stream
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: session.id) {
            Task { try? await videoStream.close() }
        }
        transportRegistry.unregisterVideoStream(streamID: session.id)

        // Minimize the window if requested (after stopping capture so window is restored from virtual display)
        if minimizeWindow { WindowManager.minimizeWindow(windowID) }

        if updateAppSession {
            await removeStoppedWindowFromAppSessionIfNeeded(windowID: windowID)
            if let appSessionForStoppedWindow,
               let clientContext = findClientContext(clientID: appSessionForStoppedWindow.clientID) {
                await emitWindowRemovedFromStream(
                    to: clientContext,
                    bundleIdentifier: appSessionForStoppedWindow.bundleIdentifier,
                    windowID: windowID,
                    reason: .noLongerEligible
                )
            }
        }

        await updateLightsOutState()
        lockHostIfStreamingStopped()

        if activeStreams.isEmpty {
            await PowerAssertionManager.shared.disable()
        }
        await stopAppStreamGovernorsIfIdle()
    }

    func notifyWindowResized(_ window: MirageWindow) async {
        // Find any active streams for this window and update their dimensions
        let latestFrame = currentWindowFrame(for: window.id) ?? window.frame
        let updatedWindow = MirageWindow(
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
            if let bounds = getVirtualDisplayBounds(windowID: window.id) {
                inputStreamCacheActor.updateWindowFrame(session.id, newFrame: bounds)
            }
            await enforceVirtualDisplayPlacementAfterActivation(windowID: window.id)
            return
        }

        registerActiveStreamSession(
            MirageStreamSession(
                id: session.id,
                window: updatedWindow,
                client: session.client
            )
        )

        // Update input cache with new frame - critical for mouse coordinate translation
        inputStreamCacheActor.updateWindowFrame(session.id, newFrame: latestFrame)

        do {
            // Update capture/encoder to scaled resolution
            try await context.updateDimensions(windowFrame: updatedWindow.frame)

            let encodedDimensions = await context.getEncodedDimensions()
            let targetFrameRate = await context.getTargetFrameRate()
            let codec = await context.getCodec()

            // Get updated dimension token after resize
            let dimensionToken = await context.getDimensionToken()

            if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = minimumSizesByWindowID[updatedWindow.id]
                let fallbackMin = fallbackMinimumSize(for: updatedWindow.frame)
                let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                let message = StreamStartedMessage(
                    streamID: session.id,
                    windowID: window.id,
                    width: encodedDimensions.width,
                    height: encodedDimensions.height,
                    frameRate: targetFrameRate,
                    codec: codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: dimensionToken
                )
                try await clientContext.send(.streamStarted, content: message)
                MirageLogger
                    .host("Encoding at scaled resolution: \(encodedDimensions.width)x\(encodedDimensions.height)")
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update stream dimensions: ")
        }
    }

    func updateCaptureResolution(for windowID: WindowID, width: Int, height: Int) async {
        // Find the stream for this window
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

        // Get the latest window frame for calculations
        let latestFrame = currentWindowFrame(for: windowID) ?? session.window.frame

        // Update the window frame in the active stream (maintains position metadata)
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
                id: session.id,
                window: updatedWindow,
                client: session.client
            )
        )

        do {
            // Request client's exact resolution - with .best, SCK will capture at highest quality
            try await context.updateResolution(width: width, height: height)

            // Get updated dimension token after resize
            let dimensionToken = await context.getDimensionToken()

            // Notify the client of the dimensions
            if let clientContext = clientsBySessionID.values.first(where: { $0.client.id == session.client.id }) {
                let minSize = minimumSizesByWindowID[windowID]
                let fallbackMin = fallbackMinimumSize(for: latestFrame)
                let minWidth = Int(minSize?.width ?? CGFloat(fallbackMin.minWidth))
                let minHeight = Int(minSize?.height ?? CGFloat(fallbackMin.minHeight))

                let message = await StreamStartedMessage(
                    streamID: session.id,
                    windowID: windowID,
                    width: width,
                    height: height,
                    frameRate: context.getTargetFrameRate(),
                    codec: encoderConfig.codec,
                    minWidth: minWidth,
                    minHeight: minHeight,
                    dimensionToken: dimensionToken
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
