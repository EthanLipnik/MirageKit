//
//  MirageClientService+WindowStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Per-window stream lifecycle and controller setup.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Start viewing a remote window.
    /// - Parameters:
    ///   - window: The remote window to stream.
    ///   - scaleFactor: Optional display scale factor (e.g., 2.0 for Retina).
    ///   - displayResolution: Client's logical display size in points.
    ///     Host applies HiDPI (2x) to determine virtual display pixel resolution.
    ///   - keyFrameInterval: Optional keyframe interval in frames. Higher = fewer lag spikes.
    ///     Examples: 600 (10 seconds @ 60fps), 300 (5 seconds @ 60fps).
    ///   - encoderOverrides: Optional per-stream encoder overrides.
    ///   - audioConfiguration: Optional per-stream audio overrides.
    func startViewing(
        window: MirageWindow,
        scaleFactor: CGFloat? = nil,
        displayResolution: CGSize? = nil,
        keyFrameInterval: Int? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil
    )
    async throws -> ClientStreamSession {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        _ = await refreshCurrentControlPathKind()

        // Note: Decoder/reassembler are created per-stream AFTER receiving streamStarted with the stream ID.
        var request = StartStreamMessage(
            windowID: window.id,
            targetFrameRate: effectiveFrameRateForCurrentMediaPath(screenMaxRefreshRate)
        )
        request.mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize
        let effectiveDisplayResolution = MirageStreamGeometry.normalizedLogicalSize(displayResolution ?? mainDisplayResolution)
        guard effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 else {
            throw MirageError.protocolError("Display size unavailable for window streaming")
        }

        // Include display resolution for virtual display sizing.
        if effectiveDisplayResolution.width > 0, effectiveDisplayResolution.height > 0 {
            request.displayWidth = Int(effectiveDisplayResolution.width)
            request.displayHeight = Int(effectiveDisplayResolution.height)
            MirageLogger
                .client(
                    "Including display size: \(Int(effectiveDisplayResolution.width))x\(Int(effectiveDisplayResolution.height)) pts"
                )
        }

        // Include encoder config overrides if specified.
        var overrides = encoderOverrides ?? MirageEncoderOverrides()
        if overrides.keyFrameInterval == nil { overrides.keyFrameInterval = keyFrameInterval }
        applyEncoderOverrides(overrides, to: &request)
        if currentMediaPathUsesAwdlRadioPolicy {
            let requestedLatency = request.latencyMode
            request.latencyMode = effectiveLatencyModeForCurrentMediaPath(request.latencyMode)
            request.hostBufferingPolicy = effectiveHostBufferingPolicyForCurrentMediaPath(request.hostBufferingPolicy)
            if requestedLatency != request.latencyMode {
                MirageLogger.client(
                    "AWDL media policy overriding requested window latency " +
                        "\(requestedLatency?.rawValue ?? "default") -> \(request.latencyMode?.rawValue ?? "default")"
                )
            }
        }
        if let colorDepth = request.colorDepth {
            pendingRequestedColorDepthByWindowID[window.id] = colorDepth
        } else {
            pendingRequestedColorDepthByWindowID.removeValue(forKey: window.id)
        }

        request.audioConfiguration = audioConfiguration ?? self.audioConfiguration
        let geometry = resolvedStreamGeometry(
            for: effectiveDisplayResolution,
            explicitScaleFactor: scaleFactor,
            requestedStreamScale: MirageStreamGeometry.clampStreamScale(resolutionScale),
            encoderMaxWidth: request.encoderMaxWidth,
            encoderMaxHeight: request.encoderMaxHeight,
            disableResolutionCap: request.disableResolutionCap == true
        )
        resolutionScale = geometry.resolvedStreamScale
        request.scaleFactor = geometry.displayScaleFactor
        request.streamScale = geometry.resolvedStreamScale
        applyCurrentClientPathFields(to: &request)

        MirageLogger.client(
            "Sending startStream for window \(window.id): " +
                "\(Int(geometry.logicalSize.width))x\(Int(geometry.logicalSize.height)) pts, " +
                "\(Int(geometry.displayPixelSize.width))x\(Int(geometry.displayPixelSize.height)) px, " +
                "encode \(Int(geometry.encodedPixelSize.width))x\(Int(geometry.encodedPixelSize.height)) px"
        )
        try await sendControlMessage(.startStream, content: request)

        // Wait for streamStarted response from server to get the real stream ID.
        let realStreamID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            StreamID,
            Error
        >) in
            self.streamStartedContinuation = continuation
        }
        let pendingColorDepth = pendingRequestedColorDepthByWindowID.removeValue(forKey: window.id)
        configureDecoderColorDepthBaseline(for: realStreamID, colorDepth: pendingColorDepth)

        MirageLogger.client("Stream started with ID \(realStreamID)")

        let session = ClientStreamSession(
            id: realStreamID,
            window: window,
            mediaStreamID: realStreamID
        )

        upsertActiveStreamSession(streamID: realStreamID, window: window)
        return session
    }

    /// Set up or reset controller for a specific stream.
    /// StreamController owns the decoder, reassembler, and resize state machine.
    func setupControllerForStream(
        _ streamID: StreamID,
        beginPostResizeTransition: Bool = false,
        codec: MirageVideoCodec = .hevc,
        streamDimensions: (width: Int, height: Int)? = nil,
        mediaMaxPacketSize: Int? = nil,
        dimensionToken: UInt16? = nil,
        targetFrameRate: Int? = nil
    )
    async {
        let preferredDecoderColorDepth = resolvedDecoderColorDepth(for: streamID)
        let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(mediaMaxPacketSize)
        let payloadSize = miragePayloadSize(maxPacketSize: acceptedMediaMaxPacketSize)
        let resolvedTargetFrameRate = resolvedStreamCadenceFrameRate(
            for: streamID,
            fallback: targetFrameRate
        )

        if let existingController = controllersByStream[streamID] {
            let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[streamID] ?? mirageDefaultMaxPacketSize
            guard previousMediaMaxPacketSize == acceptedMediaMaxPacketSize else {
                await existingController.stop()
                controllersByStream.removeValue(forKey: streamID)
                mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
                MirageLogger.client(
                    "Recreating controller for stream \(streamID) due to media packet size change \(previousMediaMaxPacketSize)B -> \(acceptedMediaMaxPacketSize)B"
                )
                return await setupControllerForStream(
                    streamID,
                    beginPostResizeTransition: beginPostResizeTransition,
                    codec: codec,
                    streamDimensions: streamDimensions,
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                    dimensionToken: dimensionToken,
                    targetFrameRate: resolvedTargetFrameRate
                )
            }

            if !beginPostResizeTransition, let dimensionToken {
                let reassembler = existingController.reassembler
                reassembler.updateExpectedDimensionToken(dimensionToken)
            }
            await existingController.setDecoderCodec(codec, streamDimensions: streamDimensions)
            await existingController.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
            await existingController.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
            await existingController.resetForNewSession()
            if beginPostResizeTransition {
                await existingController.primeForIncomingResize(
                    dimensionToken: dimensionToken,
                    streamDimensions: streamDimensions
                )
                await existingController.beginPostResizeTransition()
            }
            let tier = sessionStore.presentationTier(for: streamID)
            let requestedLatencyMode = renderLatencyModeByStream[streamID]
            let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
            let playoutDelayFrames = resolvedStreamPlayoutDelayFrames(for: latencyMode)
            await existingController.updateCadenceTarget(
                sourceFPS: resolvedTargetFrameRate,
                displayFPS: resolvedTargetFrameRate,
                latencyMode: latencyMode,
                playoutDelayFrames: playoutDelayFrames,
                reason: "controller reset"
            )
            await existingController.updatePresentationTier(tier, targetFPS: resolvedTargetFrameRate)
            if let controlPathSnapshot {
                MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: controlPathSnapshot.kind)
                MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: controlPathSnapshot.mediaProfile)
                await existingController.setTransportPathKind(controlPathSnapshot.kind)
                await existingController.setMediaPathProfile(controlPathSnapshot.mediaProfile)
            }
            mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
            MirageLogger
                .client(
                    "Reset existing controller for stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName))"
                )
            replayPendingApplicationActivationRecoveryIfNeeded(for: streamID)
            return
        }

        let controller = StreamController(streamID: streamID, maxPayloadSize: payloadSize)
        controllersByStream[streamID] = controller
        mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
        if decoderCompatibilityBaselineColorDepthByStream[streamID] == nil,
           pendingAppRequestedColorDepth != nil {
            configureDecoderColorDepthBaseline(
                for: streamID,
                colorDepth: pendingAppRequestedColorDepth
            )
        }
        await controller.setDecoderCodec(codec, streamDimensions: streamDimensions)
        await controller.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
        await controller.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
        if let dimensionToken {
            let reassembler = controller.reassembler
            reassembler.updateExpectedDimensionToken(dimensionToken)
        }

        await configureCallbacks(for: controller, streamID: streamID)

        let requestedLatencyMode = renderLatencyModeByStream[streamID]
        let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
        let playoutDelayFrames = resolvedStreamPlayoutDelayFrames(for: latencyMode)
        await controller.updateCadenceTarget(
            sourceFPS: resolvedTargetFrameRate,
            displayFPS: resolvedTargetFrameRate,
            latencyMode: latencyMode,
            playoutDelayFrames: playoutDelayFrames,
            reason: "controller setup"
        )
        if let controlPathSnapshot {
            MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: controlPathSnapshot.kind)
            MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: controlPathSnapshot.mediaProfile)
            await controller.setTransportPathKind(controlPathSnapshot.kind)
            await controller.setMediaPathProfile(controlPathSnapshot.mediaProfile)
        }
        if beginPostResizeTransition {
            await controller.beginPostResizeTransition()
        }
        await controller.start()
        await controller.updatePresentationTier(
            sessionStore.presentationTier(for: streamID),
            targetFPS: resolvedTargetFrameRate
        )
        await updateReassemblerSnapshot()

        MirageLogger
            .client(
                "Created new controller for stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName), media packet \(acceptedMediaMaxPacketSize)B)"
            )
        replayPendingApplicationActivationRecoveryIfNeeded(for: streamID)
    }

    func prepareControllerForDesktopResize(
        _ streamID: StreamID,
        codec: MirageVideoCodec,
        streamDimensions: (width: Int, height: Int)?,
        mediaMaxPacketSize: Int?,
        dimensionToken: UInt16?,
        targetFrameRate: Int? = nil
    )
    async {
        let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(mediaMaxPacketSize)
        let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[streamID] ?? mirageDefaultMaxPacketSize
        let resolvedTargetFrameRate = resolvedStreamCadenceFrameRate(
            for: streamID,
            fallback: targetFrameRate
        )
        guard previousMediaMaxPacketSize == acceptedMediaMaxPacketSize else {
            if let existingController = controllersByStream[streamID] {
                await existingController.stop()
                controllersByStream.removeValue(forKey: streamID)
                mediaMaxPacketSizeByStream.removeValue(forKey: streamID)
            }
            MirageLogger.client(
                "Recreating controller for desktop resize on stream \(streamID) due to media packet size change \(previousMediaMaxPacketSize)B -> \(acceptedMediaMaxPacketSize)B"
            )
            return await setupControllerForStream(
                streamID,
                beginPostResizeTransition: true,
                codec: codec,
                streamDimensions: streamDimensions,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                dimensionToken: dimensionToken,
                targetFrameRate: resolvedTargetFrameRate
            )
        }

        guard let existingController = controllersByStream[streamID] else {
            return await setupControllerForStream(
                streamID,
                beginPostResizeTransition: true,
                codec: codec,
                streamDimensions: streamDimensions,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                dimensionToken: dimensionToken,
                targetFrameRate: resolvedTargetFrameRate
            )
        }

        let preferredDecoderColorDepth = resolvedDecoderColorDepth(for: streamID)
        await existingController.setDecoderLowPowerEnabled(isDecoderLowPowerModeActive)
        await existingController.setPreferredDecoderColorDepth(preferredDecoderColorDepth)
        await existingController.prepareForResize(
            codec: codec,
            streamDimensions: streamDimensions
        )
        await existingController.primeForIncomingResize(
            dimensionToken: dimensionToken,
            streamDimensions: streamDimensions
        )
        await existingController.beginPostResizeTransition()
        let requestedLatencyMode = renderLatencyModeByStream[streamID]
        let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
        let playoutDelayFrames = resolvedStreamPlayoutDelayFrames(for: latencyMode)
        await existingController.updateCadenceTarget(
            sourceFPS: resolvedTargetFrameRate,
            displayFPS: resolvedTargetFrameRate,
            latencyMode: latencyMode,
            playoutDelayFrames: playoutDelayFrames,
            reason: "desktop resize"
        )
        await existingController.updatePresentationTier(
            sessionStore.presentationTier(for: streamID),
            targetFPS: resolvedTargetFrameRate
        )
        mediaMaxPacketSizeByStream[streamID] = acceptedMediaMaxPacketSize
        MirageLogger.client(
            "Prepared existing controller for desktop resize on stream \(streamID) (decoder color depth \(preferredDecoderColorDepth.displayName))"
        )
    }

    func applyRenderLatencyMode(
        to streamID: StreamID,
        preferredLatencyMode: MirageStreamLatencyMode? = nil
    ) {
        let requestedLatencyMode = preferredLatencyMode ??
            renderLatencyModeByStream[streamID] ??
            .lowestLatency
        let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
        renderLatencyModeByStream[streamID] = latencyMode
        MirageRenderStreamStore.shared.setLatencyMode(
            for: streamID,
            latencyMode: latencyMode,
            playoutDelayFrames: resolvedStreamPlayoutDelayFrames(for: latencyMode)
        )
    }

    /// Preferred media packet size for the current control path.
    var resolvedRequestedMediaMaxPacketSize: Int {
        miragePreferredMediaMaxPacketSize(
            for: controlPathSnapshot?.mediaProfile,
            pathKind: controlPathSnapshot?.kind
        )
    }

    /// Negotiated media packet size after applying control-path limits.
    func resolvedAcceptedMediaMaxPacketSize(_ accepted: Int?) -> Int {
        mirageNegotiatedMediaMaxPacketSize(
            requested: accepted,
            mediaPathProfile: controlPathSnapshot?.mediaProfile,
            pathKind: controlPathSnapshot?.kind
        )
    }

    func resolvedDecoderColorDepth(for streamID: StreamID) -> MirageStreamColorDepth {
        decoderCompatibilityCurrentColorDepthByStream[streamID] ??
            decoderCompatibilityBaselineColorDepthByStream[streamID] ??
            .standard
    }

    /// Applies a presentation tier update to the controller for an active stream.
    func applyStreamPresentationTier(_ tier: StreamPresentationTier, to streamID: StreamID) async {
        guard let controller = controllersByStream[streamID] else { return }
        let targetFrameRate = resolvedStreamCadenceFrameRate(for: streamID)
        await controller.updatePresentationTier(tier, targetFPS: targetFrameRate)
    }

    /// Applies host-issued stream policies to active controllers.
    func applyHostStreamPolicies(_ policies: [MirageStreamPolicy], epoch: UInt64) async {
        for policy in policies {
            guard let controller = controllersByStream[policy.streamID] else { continue }
            let requestedLatencyMode = renderLatencyModeByStream[policy.streamID]
            let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
            let playoutDelayFrames = resolvedStreamPlayoutDelayFrames(for: latencyMode)
            let targetFPS = Self.runtimeWorkloadSafetyCappedFrameRate(
                policy.targetFPS,
                cap: runtimeWorkloadSafetyFrameRateCap(for: policy.streamID)
            )
            await controller.updateCadenceTarget(
                sourceFPS: targetFPS,
                displayFPS: targetFPS,
                latencyMode: latencyMode,
                playoutDelayFrames: playoutDelayFrames,
                reason: "host stream policy"
            )
            let tier: StreamPresentationTier = switch policy.tier {
            case .activeLive:
                .activeLive
            case .passiveSnapshot:
                .passiveSnapshot
            }
            await controller.updatePresentationTier(tier, targetFPS: targetFPS)
        }
        let policyText = policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            let targetFPS = Self.runtimeWorkloadSafetyCappedFrameRate(
                policy.targetFPS,
                cap: runtimeWorkloadSafetyFrameRateCap(for: policy.streamID)
            )
            return "\(policy.streamID)=\(policy.tier.rawValue):\(targetFPS)fps@\(bitrate)"
        }.joined(separator: ", ")
        MirageLogger.client("Applied host stream policy update epoch=\(epoch): [\(policyText)]")
    }
}
