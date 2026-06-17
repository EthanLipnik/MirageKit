//
//  MirageClientService+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Desktop streaming requests.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Start streaming the desktop (unified or secondary display mode).
    /// - Parameters:
    ///   - scaleFactor: Optional display scale factor.
    ///   - displayResolution: Client's logical display size in points for virtual display sizing.
    ///   - mode: Desktop stream mode (unified vs secondary display).
    ///   - keyFrameInterval: Optional keyframe interval in frames.
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    func startDesktopStream(
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        mode: MirageDesktopStreamMode = .unified,
        cursorPresentation: MirageDesktopCursorPresentation = .simulatedCursor,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        useHostResolution: Bool = false
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        _ = await refreshCurrentControlPathKind()

        let baseResolution = try resolvedDesktopStartupBaseResolution(
            displayResolution: displayResolution,
            useHostResolution: useHostResolution
        )
        guard baseResolution.width > 0, baseResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable")
        }
        let effectiveDisplayResolution = MirageStreamGeometry.normalizedLogicalSize(baseResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Invalid display resolution")
        }
        let targetFrameRate = effectiveFrameRateForCurrentMediaPath(screenMaxRefreshRate)
        desktopStreamMode = mode
        desktopCursorPresentation = cursorPresentation

        let resolvedAudioConfiguration = (audioConfiguration ?? self.audioConfiguration)
            .resolvedForDesktopStreamMode(mode)
        MirageLogger.client(
            "Desktop stream audio request: enabled=\(resolvedAudioConfiguration.enabled), " +
                "layout=\(resolvedAudioConfiguration.channelLayout.rawValue), " +
                "quality=\(resolvedAudioConfiguration.quality.rawValue), " +
                "bitrate=\(resolvedAudioConfiguration.compressedBitrateBps.map(String.init) ?? "default"), " +
                "ceiling=\(resolvedAudioConfiguration.compressedBitrateCeilingBps.map(String.init) ?? "default"), " +
                "adaptive=\(resolvedAudioConfiguration.adaptiveCompressionEnabled), mode=\(mode.rawValue)"
        )

        let startupRequestID = UUID()
        pendingStreamSetupRequestID = startupRequestID
        pendingStreamSetupKind = .desktop
        pendingStreamSetupAppSessionID = nil

        var encoderRequest = StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: nil,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            targetFrameRate: targetFrameRate,
            keyFrameInterval: nil,
            mode: mode,
            cursorPresentation: cursorPresentation,
            bitrate: nil,
            streamScale: nil,
            audioConfiguration: resolvedAudioConfiguration,
            dataPort: nil,
            useHostResolution: useHostResolution ? true : nil,
            mediaMaxPacketSize: resolvedRequestedMediaMaxPacketSize
        )

        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &encoderRequest)
        let usesHostResolution = encoderRequest.useHostResolution == true
        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor,
            requestedStreamScale: MirageStreamGeometry.clampStreamScale(resolutionScale),
            encoderMaxWidth: encoderRequest.encoderMaxWidth,
            encoderMaxHeight: encoderRequest.encoderMaxHeight,
            disableResolutionCap: encoderRequest.disableResolutionCap == true
        )
        resolutionScale = geometry.resolvedStreamScale
        desktopStreamDisplayScaleFactor = geometry.displayScaleFactor
        let startupGeometryTarget: DesktopResizeCoordinator.RequestGeometry?
        if usesHostResolution {
            startupGeometryTarget = nil
            desktopResizeCoordinator.lastSentTarget = nil
        } else {
            let target = DesktopResizeCoordinator.RequestGeometry(
                refreshTargetHz: targetFrameRate,
                logicalResolution: effectiveDisplayResolution,
                displayScaleFactor: geometry.displayScaleFactor,
                requestedStreamScale: geometry.resolvedStreamScale,
                encoderMaxWidth: encoderRequest.encoderMaxWidth,
                encoderMaxHeight: encoderRequest.encoderMaxHeight,
                disableResolutionCap: encoderRequest.disableResolutionCap == true
            )
            startupGeometryTarget = target
            desktopResizeCoordinator.lastSentTarget = target
        }
        let bitrateSemantics = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: encoderRequest.enteredBitrate,
            requestedTargetBitrateBps: encoderRequest.bitrate,
            bitrateAdaptationCeilingBps: encoderRequest.bitrateAdaptationCeiling,
            displayResolution: effectiveDisplayResolution
        )
        var request = StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: geometry.displayScaleFactor,
            displayWidth: encoderRequest.displayWidth,
            displayHeight: encoderRequest.displayHeight,
            targetFrameRate: encoderRequest.targetFrameRate,
            streamScale: geometry.resolvedStreamScale,
            audioConfiguration: encoderRequest.audioConfiguration,
            dataPort: encoderRequest.dataPort,
            useHostResolution: encoderRequest.useHostResolution,
            mediaMaxPacketSize: encoderRequest.mediaMaxPacketSize
        )
        request.keyFrameInterval = encoderRequest.keyFrameInterval
        request.captureQueueDepth = encoderRequest.captureQueueDepth
        request.colorDepth = encoderRequest.colorDepth
        request.mode = encoderRequest.mode
        request.cursorPresentation = encoderRequest.cursorPresentation
        request.enteredBitrate = bitrateSemantics.enteredBitrateBps
        request.bitrate = bitrateSemantics.requestedTargetBitrateBps
        request.latencyMode = encoderRequest.latencyMode
        request.hostBufferingPolicy = encoderRequest.hostBufferingPolicy
        if currentMediaPathUsesAwdlRadioPolicy {
            let requestedLatency = request.latencyMode
            request.latencyMode = effectiveLatencyModeForCurrentMediaPath(request.latencyMode)
            request.hostBufferingPolicy = effectiveHostBufferingPolicyForCurrentMediaPath(request.hostBufferingPolicy)
            if requestedLatency != request.latencyMode {
                MirageLogger.client(
                    "AWDL media policy overriding requested desktop latency " +
                        "\(requestedLatency?.rawValue ?? "default") -> \(request.latencyMode?.rawValue ?? "default")"
                )
            }
        }
        request.allowRuntimeQualityAdjustment = encoderRequest.allowRuntimeQualityAdjustment
        request.allowEncoderCatchUpQualityAdjustment = encoderRequest.allowEncoderCatchUpQualityAdjustment
        request.lowLatencyHighResolutionCompressionBoost =
            effectiveLowLatencyHighResolutionCompressionBoostForCurrentMediaPath(
                encoderRequest.lowLatencyHighResolutionCompressionBoost
            )
        request.disableResolutionCap = encoderRequest.disableResolutionCap
        request.bitrateAdaptationCeiling = bitrateSemantics.bitrateAdaptationCeilingBps
        request.encoderMaxWidth = encoderRequest.encoderMaxWidth
        request.encoderMaxHeight = encoderRequest.encoderMaxHeight
        if let startupGeometryTarget {
            request.desktopGeometryContractID = startupGeometryTarget.contractID
            request.desktopGeometrySceneIdentity = startupGeometryTarget.sceneIdentity
            request.desktopGeometryDisplayPixelWidth = Int(geometry.displayPixelSize.width.rounded())
            request.desktopGeometryDisplayPixelHeight = Int(geometry.displayPixelSize.height.rounded())
            request.desktopGeometryEncodedPixelWidth = Int(geometry.encodedPixelSize.width.rounded())
            request.desktopGeometryEncodedPixelHeight = Int(geometry.encodedPixelSize.height.rounded())
            request.desktopGeometryRefreshTargetHz = startupGeometryTarget.refreshTargetHz ?? targetFrameRate
        }
        request.upscalingMode = encoderRequest.upscalingMode
        request.codec = encoderRequest.codec
        applyCurrentClientPathFields(to: &request)
        pendingDesktopRequestedColorDepth = request.colorDepth
        pendingDesktopRequestedLatencyMode = request.latencyMode ?? .lowestLatency
        pendingStreamSetupLatencyMode = request.latencyMode ?? .lowestLatency
        desktopStreamRestartAttempts = 0
        lastDesktopStreamStartRequest = request

        let enteredBitrateText = request.enteredBitrate.map(mirageFormattedMegabitRate) ?? "n/a"
        let requestedBitrateText = request.bitrate.map(mirageFormattedMegabitRate) ?? "auto"
        let ceilingText = request.bitrateAdaptationCeiling.map(mirageFormattedMegabitRate) ?? "none"
        let requestedCadence = max(1, request.targetFrameRate)
        let adaptiveFloorFPS = requestedCadence >= 90 ? 60 : requestedCadence
        let pathKind = controlPathSnapshot?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue
        let requestLatencyMode = request.latencyMode ?? .lowestLatency
        MirageLogger.client(
            "Desktop bitrate contract requested: entered=\(enteredBitrateText) requested=\(requestedBitrateText) ceiling=\(ceilingText) " +
                "scale=\(String(format: "%.3f", bitrateSemantics.geometryScaleFactor)) display=\(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height))"
        )
        MirageLogger.client(
            "event=cadence_contract phase=desktop_start requested=\(requestedCadence) " +
                "source=\(requestedCadence) display=\(requestedCadence) adaptiveFloor=\(adaptiveFloorFPS) " +
                "path=\(pathKind) latency=\(requestLatencyMode.rawValue)"
        )

        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()
        MirageLogger.client("Desktop start: request sent")
        try await sendControlMessage(.startDesktopStream, content: request)
        // Desktop startup shares the same control channel as metadata refreshes,
        // startup acks, and refresh-override traffic. Extend heartbeat grace so
        // we do not tear down the control session while startup control work is
        // still in flight.
        heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
        scheduleDesktopStreamStartTimeout()

        MirageLogger
            .client(
                "Requested desktop stream: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height)) pts " +
                    "(\(Int(geometry.displayPixelSize.width))x\(Int(geometry.displayPixelSize.height)) px, " +
                    "encode \(Int(geometry.encodedPixelSize.width))x\(Int(geometry.encodedPixelSize.height)) px, " +
                    "scale \(String(format: "%.3f", geometry.displayScaleFactor))x, " +
                    "stream \(String(format: "%.3f", geometry.resolvedStreamScale)))"
            )
    }

    /// Sends the client's preferred desktop cursor presentation mode for a stream.
    func sendDesktopCursorPresentationChange(
        streamID: StreamID,
        cursorPresentation: MirageDesktopCursorPresentation
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        let request = DesktopCursorPresentationChangeMessage(
            streamID: streamID,
            cursorPresentation: cursorPresentation
        )
        try await sendControlMessage(.desktopCursorPresentationChange, content: request)
        desktopCursorPresentation = cursorPresentation
    }

    private static let desktopStreamStartTimeoutSeconds: Double = 30

    private func scheduleDesktopStreamStartTimeout() {
        desktopStreamStartTimeoutTask?.cancel()
        desktopStreamStartTimeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(Self.desktopStreamStartTimeoutSeconds))
            guard let self else { return }
            guard desktopStreamMode != nil, desktopStreamID == nil,
                  desktopStreamRequestStartTime > 0 else { return }
            MirageLogger.error(
                .client,
                "Desktop stream start timed out after \(Int(Self.desktopStreamStartTimeoutSeconds))s"
            )
            suppressCurrentAwdlProximityRouteIfNeeded(
                reason: "desktop stream start timed out before host acknowledgement"
            )
            cancelStreamSetup()
            clearPendingDesktopStreamStartState()
            delegate?.didEncounterError(
                MirageError.protocolError("Desktop stream start timed out. The host may be busy or unreachable.")
            )
        }
    }

    /// Stop the current desktop stream.
    func stopDesktopStream() async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        guard let streamID = desktopStreamID else {
            cancelDesktopStreamStopTimeout()
            MirageLogger.client("No active desktop stream to stop")
            return
        }

        guard let desktopSessionID else {
            throw MirageError.protocolError("Desktop stream missing session identifier")
        }

        let request = StopDesktopStreamMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID
        )
        pendingLocalDesktopStopStreamID = streamID
        pendingLocalDesktopStopSessionID = desktopSessionID
        clearDesktopResizeState(streamID: streamID)

        do {
            try await sendControlMessage(.stopDesktopStream, content: request)
        } catch {
            if pendingLocalDesktopStopStreamID == streamID,
               pendingLocalDesktopStopSessionID == desktopSessionID {
                cancelDesktopStreamStopTimeout()
            }
            throw error
        }

        scheduleDesktopStreamStopTimeout(for: streamID, desktopSessionID: desktopSessionID)

        MirageLogger.client(
            "Requested stop desktop stream: stream=\(streamID), session=\(desktopSessionID.uuidString)"
        )
    }
}

extension MirageClientService {
    func hasDesktopStreamRestartBudget(streamID: StreamID) -> Bool {
        desktopStreamID == streamID &&
            lastDesktopStreamStartRequest != nil &&
            desktopStreamRestartAttempts < desktopStreamRestartLimit
    }

    func restartDesktopStreamAfterTerminalStartupFailure(
        _ failure: StreamController.TerminalStartupFailure,
        failedStreamID: StreamID
    ) async -> Bool {
        guard case .connected = connectionState,
              controlChannel != nil,
              hasDesktopStreamRestartBudget(streamID: failedStreamID),
              let previousRequest = lastDesktopStreamStartRequest else {
            return false
        }

        let failedDesktopSessionID = desktopSessionID
        guard var restartRequest = rebuiltDesktopRestartRequest(from: previousRequest) else {
            MirageLogger.client(
                "Desktop restart suppressed after terminal startup failure: current drawable geometry unavailable"
            )
            return false
        }
        applyCurrentClientPathFields(to: &restartRequest)
        desktopStreamRestartAttempts += 1
        MirageLogger.client(
            "Restarting desktop stream in-session after terminal startup failure: " +
                "failedStream=\(failedStreamID), attempt=\(desktopStreamRestartAttempts)/\(desktopStreamRestartLimit), " +
                "reason=\(failure.reason.logLabel), startupRequest=\(restartRequest.startupRequestID.uuidString), " +
                "contract=\(restartRequest.desktopGeometryContractID?.uuidString ?? "nil"), " +
                "path=\(controlPathSnapshot?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue)"
        )

        if let failedDesktopSessionID {
            let stopRequest = StopDesktopStreamMessage(
                streamID: failedStreamID,
                desktopSessionID: failedDesktopSessionID
            )
            queueControlMessageBestEffort(.stopDesktopStream, content: stopRequest)
        }

        await forceStopDesktopStreamLocally(
            streamID: failedStreamID,
            desktopSessionID: failedDesktopSessionID,
            notifyStopReason: nil
        )

        guard case .connected = connectionState else { return false }

        lastDesktopStreamStartRequest = restartRequest
        pendingStreamSetupRequestID = restartRequest.startupRequestID
        pendingStreamSetupKind = .desktop
        pendingStreamSetupAppSessionID = nil
        pendingStreamSetupLatencyMode = restartRequest.latencyMode ?? .lowestLatency
        pendingDesktopRequestedColorDepth = restartRequest.colorDepth
        pendingDesktopRequestedLatencyMode = restartRequest.latencyMode ?? .lowestLatency
        desktopStreamMode = restartRequest.mode ?? .unified
        desktopCursorPresentation = restartRequest.cursorPresentation
        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        do {
            try await sendControlMessage(.startDesktopStream, content: restartRequest)
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            scheduleDesktopStreamStartTimeout()
            MirageLogger.client(
                "Desktop restart: request sent after terminal startup failure for stream \(failedStreamID)"
            )
            return true
        } catch {
            MirageLogger.error(.client, error: error, message: "Desktop restart failed after terminal startup failure: ")
            clearPendingDesktopStreamStartState()
            return false
        }
    }

    @discardableResult
    func resendPendingDesktopStartAfterGeometryContractRejection(reason: String) async -> Bool {
        guard case .connected = connectionState,
              controlChannel != nil,
              desktopStreamID == nil,
              desktopStreamRequestStartTime > 0,
              let previousRequest = lastDesktopStreamStartRequest,
              previousRequest.desktopGeometryContractID != nil,
              desktopStreamRestartAttempts < desktopStreamRestartLimit else {
            return false
        }

        guard var retryRequest = rebuiltDesktopRestartRequest(
            from: previousRequest,
            requiresFreshAwdlGeometry: true
        ) else {
            MirageLogger.client(
                "Unable to retry AWDL desktop start after geometry-contract rejection: " +
                    "reason=\(reason), startupRequest=\(previousRequest.startupRequestID.uuidString)"
            )
            return false
        }
        applyCurrentClientPathFields(to: &retryRequest)
        desktopStreamRestartAttempts += 1
        lastDesktopStreamStartRequest = retryRequest
        pendingStreamSetupRequestID = retryRequest.startupRequestID
        pendingStreamSetupKind = .desktop
        pendingStreamSetupAppSessionID = nil
        pendingStreamSetupLatencyMode = retryRequest.latencyMode ?? .lowestLatency
        pendingDesktopRequestedColorDepth = retryRequest.colorDepth
        pendingDesktopRequestedLatencyMode = retryRequest.latencyMode ?? .lowestLatency
        desktopStreamMode = retryRequest.mode ?? desktopStreamMode ?? .unified
        desktopCursorPresentation = retryRequest.cursorPresentation ?? desktopCursorPresentation
        desktopStreamRequestStartTime = CFAbsoluteTimeGetCurrent()

        do {
            try await sendControlMessage(.startDesktopStream, content: retryRequest)
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            scheduleDesktopStreamStartTimeout()
            MirageLogger.client(
                "Retried AWDL desktop start after geometry-contract rejection: " +
                    "reason=\(reason), startupRequest=\(retryRequest.startupRequestID.uuidString), " +
                    "contract=\(retryRequest.desktopGeometryContractID?.uuidString ?? "nil")"
            )
            return true
        } catch {
            MirageLogger.error(.client, error: error, message: "AWDL desktop start geometry retry failed: ")
            return false
        }
    }

    package func rebuiltDesktopRestartRequest(
        from previousRequest: StartDesktopStreamMessage,
        requiresFreshAwdlGeometry: Bool = false
    ) -> StartDesktopStreamMessage? {
        let usesHostResolution = previousRequest.useHostResolution == true
        let usesAwdlRadioPolicy = currentMediaPathUsesAwdlRadioPolicy
        let previousRequestResolution = CGSize(
            width: previousRequest.displayWidth,
            height: previousRequest.displayHeight
        )
        let liveAwdlGeometryTarget = usesHostResolution ? nil : currentAwdlDesktopRestartGeometryTarget()
        if usesAwdlRadioPolicy,
           !usesHostResolution,
           requiresFreshAwdlGeometry,
           liveAwdlGeometryTarget == nil {
            MirageLogger.client(
                "AWDL desktop restart suppressed because fresh scene-local geometry is unavailable"
            )
            return nil
        }
        let reusesPreviousAwdlGeometryContract = usesAwdlRadioPolicy &&
            !usesHostResolution &&
            liveAwdlGeometryTarget == nil &&
            previousRequest.desktopGeometryContractID != nil
        let baseResolution = if usesHostResolution {
            previousRequestResolution
        } else if let liveAwdlGeometryTarget {
            liveAwdlGeometryTarget.logicalResolution
        } else if usesAwdlRadioPolicy {
            previousRequestResolution
        } else {
            mainDisplayResolution
        }
        guard baseResolution.width > 0, baseResolution.height > 0 else { return nil }
        let effectiveDisplayResolution = MirageStreamGeometry.normalizedLogicalSize(baseResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else { return nil }

        let pathTargetFrameRate = effectiveFrameRateForCurrentMediaPath(screenMaxRefreshRate)
        let targetFrameRate = liveAwdlGeometryTarget?.refreshTargetHz ??
            (reusesPreviousAwdlGeometryContract ? previousRequest.desktopGeometryRefreshTargetHz : nil) ??
            pathTargetFrameRate
        let requestedDisplayScaleFactor = liveAwdlGeometryTarget?.displayScaleFactor ?? previousRequest.scaleFactor
        let requestedStreamScale = liveAwdlGeometryTarget?.requestedStreamScale ??
            MirageStreamGeometry.clampStreamScale(previousRequest.streamScale ?? resolutionScale)
        let encoderMaxWidth = liveAwdlGeometryTarget?.encoderMaxWidth ?? previousRequest.encoderMaxWidth
        let encoderMaxHeight = liveAwdlGeometryTarget?.encoderMaxHeight ?? previousRequest.encoderMaxHeight
        let disableResolutionCap = liveAwdlGeometryTarget?.disableResolutionCap ??
            (previousRequest.disableResolutionCap == true)
        let disableResolutionCapRequestValue = liveAwdlGeometryTarget == nil
            ? previousRequest.disableResolutionCap
            : (disableResolutionCap ? true : nil)
        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: requestedDisplayScaleFactor,
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
        resolutionScale = geometry.resolvedStreamScale
        desktopStreamDisplayScaleFactor = geometry.displayScaleFactor
        let geometryTarget: DesktopResizeCoordinator.RequestGeometry?
        if usesHostResolution {
            geometryTarget = nil
            desktopResizeCoordinator.lastSentTarget = nil
        } else if usesAwdlRadioPolicy,
                  liveAwdlGeometryTarget == nil,
                  previousRequest.desktopGeometryContractID == nil {
            geometryTarget = nil
            desktopResizeCoordinator.lastSentTarget = nil
        } else {
            let target = DesktopResizeCoordinator.RequestGeometry(
                contractID: liveAwdlGeometryTarget?.contractID ??
                    (reusesPreviousAwdlGeometryContract ? previousRequest.desktopGeometryContractID : nil) ??
                    UUID(),
                sceneIdentity: liveAwdlGeometryTarget?.sceneIdentity ?? previousRequest.desktopGeometrySceneIdentity,
                refreshTargetHz: targetFrameRate,
                logicalResolution: effectiveDisplayResolution,
                displayScaleFactor: geometry.displayScaleFactor,
                requestedStreamScale: geometry.resolvedStreamScale,
                encoderMaxWidth: encoderMaxWidth,
                encoderMaxHeight: encoderMaxHeight,
                disableResolutionCap: disableResolutionCap
            )
            geometryTarget = target
            desktopResizeCoordinator.lastSentTarget = target
        }
        if let liveAwdlGeometryTarget {
            MirageLogger.client(
                "AWDL desktop restart using current drawable geometry: " +
                    "previous=\(Int(previousRequestResolution.width))x\(Int(previousRequestResolution.height)) " +
                    "current=\(Int(liveAwdlGeometryTarget.logicalResolution.width))x\(Int(liveAwdlGeometryTarget.logicalResolution.height)) " +
                    "contract=\(liveAwdlGeometryTarget.contractID.uuidString)"
            )
        } else if reusesPreviousAwdlGeometryContract {
            MirageLogger.client(
                "AWDL desktop restart reusing previous geometry contract: " +
                    "display=\(Int(previousRequestResolution.width))x\(Int(previousRequestResolution.height)) " +
                    "contract=\(previousRequest.desktopGeometryContractID?.uuidString ?? "nil")"
            )
        }

        let bitrateSemantics = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: previousRequest.enteredBitrate,
            requestedTargetBitrateBps: previousRequest.bitrate,
            bitrateAdaptationCeilingBps: previousRequest.bitrateAdaptationCeiling,
            displayResolution: effectiveDisplayResolution,
            scaleAutomaticTargetBitrate: false
        )
        var latencyMode = previousRequest.latencyMode
        var hostBufferingPolicy = previousRequest.hostBufferingPolicy
        if usesAwdlRadioPolicy {
            latencyMode = effectiveLatencyModeForCurrentMediaPath(latencyMode)
            hostBufferingPolicy = effectiveHostBufferingPolicyForCurrentMediaPath(hostBufferingPolicy)
        }
        let lowLatencyHighResolutionCompressionBoost =
            effectiveLowLatencyHighResolutionCompressionBoostForCurrentMediaPath(
                previousRequest.lowLatencyHighResolutionCompressionBoost
            )

        var request = StartDesktopStreamMessage(
            startupRequestID: UUID(),
            scaleFactor: geometry.displayScaleFactor,
            displayWidth: Int(effectiveDisplayResolution.width),
            displayHeight: Int(effectiveDisplayResolution.height),
            targetFrameRate: targetFrameRate,
            keyFrameInterval: previousRequest.keyFrameInterval,
            captureQueueDepth: previousRequest.captureQueueDepth,
            colorDepth: previousRequest.colorDepth,
            mode: previousRequest.mode,
            cursorPresentation: previousRequest.cursorPresentation,
            enteredBitrate: bitrateSemantics.enteredBitrateBps,
            bitrate: bitrateSemantics.requestedTargetBitrateBps,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            allowRuntimeQualityAdjustment: previousRequest.allowRuntimeQualityAdjustment,
            allowEncoderCatchUpQualityAdjustment: previousRequest.allowEncoderCatchUpQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: disableResolutionCapRequestValue,
            streamScale: geometry.resolvedStreamScale,
            audioConfiguration: previousRequest.audioConfiguration,
            dataPort: previousRequest.dataPort,
            useHostResolution: previousRequest.useHostResolution,
            mediaMaxPacketSize: previousRequest.mediaMaxPacketSize,
            desktopGeometryContractID: geometryTarget?.contractID,
            desktopGeometrySceneIdentity: geometryTarget?.sceneIdentity,
            desktopGeometryDisplayPixelWidth: geometryTarget.map { _ in Int(geometry.displayPixelSize.width.rounded()) },
            desktopGeometryDisplayPixelHeight: geometryTarget.map { _ in Int(geometry.displayPixelSize.height.rounded()) },
            desktopGeometryEncodedPixelWidth: geometryTarget.map { _ in Int(geometry.encodedPixelSize.width.rounded()) },
            desktopGeometryEncodedPixelHeight: geometryTarget.map { _ in Int(geometry.encodedPixelSize.height.rounded()) },
            desktopGeometryRefreshTargetHz: geometryTarget.map { $0.refreshTargetHz ?? targetFrameRate }
        )
        request.bitrateAdaptationCeiling = bitrateSemantics.bitrateAdaptationCeilingBps
        request.encoderMaxWidth = encoderMaxWidth
        request.encoderMaxHeight = encoderMaxHeight
        request.upscalingMode = previousRequest.upscalingMode
        request.codec = previousRequest.codec
        return request
    }

    private func currentAwdlDesktopRestartGeometryTarget() -> DesktopResizeCoordinator.RequestGeometry? {
        guard currentMediaPathUsesAwdlRadioPolicy else { return nil }
        for target in [
            desktopResizeCoordinator.queuedTarget,
            desktopResizeCoordinator.latestRequestedTarget
        ].compactMap({ $0 }) {
            let normalized = MirageStreamGeometry.normalizedLogicalSize(target.logicalResolution)
            if normalized.width > 0, normalized.height > 0 {
                return target
            }
        }
        return nil
    }

    package func resolvedDesktopStartupBaseResolution(
        displayResolution: CGSize?,
        useHostResolution: Bool
    ) throws -> CGSize {
        if let displayResolution {
            return displayResolution
        }
        if currentMediaPathUsesAwdlRadioPolicy, !useHostResolution {
            MirageLogger.client(
                "Desktop startup suppressed on proximity media path because no scene-local display size was supplied"
            )
            throw MirageError.protocolError("Current display size unavailable for desktop startup")
        }
        return mainDisplayResolution
    }

    /// Cancel any in-progress stream setup on the host.
    /// Used when the user cancels during loading before a stream ID is established.
    public func cancelStreamSetup() {
        guard case .connected = connectionState else { return }
        queueControlMessageBestEffort(
            .cancelStreamSetup,
            content: CancelStreamSetupMessage(
                startupRequestID: pendingStreamSetupRequestID,
                kind: pendingStreamSetupKind,
                appSessionID: pendingStreamSetupAppSessionID
            )
        )
        if pendingStreamSetupKind == .desktop {
            clearPendingDesktopStreamStartState()
        } else {
            clearPendingStreamSetup()
        }
        MirageLogger.client("Sent cancel stream setup")
    }
}
