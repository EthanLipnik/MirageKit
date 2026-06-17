//
//  MirageHostService+DesktopStreamActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension MirageHostService {
    /// Registers desktop stream state, opens transport, and starts display capture.
    func activateAndStartDesktopStream(
        _ activation: DesktopStreamActivation,
        virtualDisplaySetupGuardToken: inout UUID?
    )
    async throws -> DesktopStreamActivationResult {
        let streamID = activation.streamID
        let clientContext = activation.clientContext
        let streamContext = activation.streamContext

        desktopStreamContext = streamContext
        desktopStreamID = streamID
        desktopStreamClientContext = clientContext
        desktopRequestedScaleFactor = activation.requestedScaleFactor
        streamsByID[streamID] = streamContext
        notifyActiveStreamActivityChanged()
        await syncAppListRequestDeferralForInteractiveWorkload()

        var effectiveAudioConfiguration = await activateDesktopAudioIfPossible(
            activation.audioConfiguration,
            clientContext: clientContext,
            streamID: streamID,
            streamContext: streamContext
        )
        guard !disconnectingClientIDs.contains(clientContext.client.id),
              let activeClientContext = findClientContext(sessionID: clientContext.sessionID) else {
            MirageLogger.host("Desktop stream client disconnected after audio activation; aborting startup")
            await cleanupFailedDesktopStreamStartup(
                mode: activation.mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_client_disconnected_after_audio_activation"
            )
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }
        desktopStreamClientContext = activeClientContext

        let excludedWindows = try await prepareDesktopInputAndPowerState(
            activation,
            activeClientContext: activeClientContext,
            virtualDisplaySetupGuardToken: &virtualDisplaySetupGuardToken
        )
        let activeVideoStream = try await openDesktopVideoStream(
            streamID: streamID,
            activeClientContext: activeClientContext,
            mode: activation.mode,
            startupRequestID: activation.startupRequestID
        )
        let mediaSendProfile = await activeClientContext.controlChannel.session.mirageMediaSendProfile(
            resolvedMediaPathProfile: streamContext.mediaPathProfile,
            streamID: streamID,
            phase: "desktop_activation"
        )

        do {
            try await startDesktopDisplayCapture(
                activation,
                activeVideoStream: activeVideoStream,
                mediaSendProfile: mediaSendProfile,
                excludedWindows: excludedWindows,
                audioConfiguration: &effectiveAudioConfiguration
            )
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Desktop display capture start failed; cleaning up stream state: "
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            throw error
        }
        return DesktopStreamActivationResult(
            activeClientContext: activeClientContext,
            audioConfiguration: effectiveAudioConfiguration
        )
    }

    /// Activates desktop audio when requested, falling back to video-only startup on failure.
    func activateDesktopAudioIfPossible(
        _ audioConfiguration: MirageAudioConfiguration,
        clientContext: ClientContext,
        streamID: StreamID,
        streamContext: StreamContext
    ) async -> MirageAudioConfiguration {
        var effectiveAudioConfiguration = audioConfiguration
        guard effectiveAudioConfiguration.enabled else { return effectiveAudioConfiguration }

        do {
            try await activateAudioForClient(
                clientID: clientContext.client.id,
                expectedSessionID: clientContext.sessionID,
                sourceStreamID: streamID,
                configuration: effectiveAudioConfiguration
            )
        } catch {
            MirageLogger.host(
                "Desktop audio activation failed; retrying desktop stream without audio: " +
                    "\(error.localizedDescription)"
            )
            effectiveAudioConfiguration.enabled = false
            audioConfigurationByClientID[clientContext.client.id] = effectiveAudioConfiguration
            await stopAudioPipeline(for: clientContext.client.id, reason: .error)
            await closeAudioTransportIfNeeded(for: clientContext.client.id)
            await streamContext.setCapturedAudioHandler(nil)
        }
        return effectiveAudioConfiguration
    }

    /// Prepares input routing, Lights Out, power assertion, and excluded windows for desktop capture.
    func prepareDesktopInputAndPowerState(
        _ activation: DesktopStreamActivation,
        activeClientContext: ClientContext,
        virtualDisplaySetupGuardToken: inout UUID?
    )
    async throws -> [SCWindowWrapper] {
        syncSharedClipboardState()
        await updateLightsOutState()
        let excludedWindows = await resolveLightsOutExcludedWindows()
        try await ensureDesktopStreamStartupCanContinue(
            streamID: activation.streamID,
            clientSessionID: activation.clientContext.sessionID,
            startupRequestID: activation.startupRequestID,
            mode: activation.mode,
            stage: "after Lights Out setup"
        )

        let mainDisplayBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputGeometry = updateDesktopInputGeometry(
            streamID: activation.streamID,
            physicalBounds: mainDisplayBounds,
            virtualResolution: activation.captureResolution
        )
        let desktopWindow = MirageWindow(
            id: 0,
            title: "Desktop",
            application: nil,
            frame: inputGeometry.inputBounds,
            isOnScreen: true,
            windowLayer: 0
        )
        inputStreamCache.set(activation.streamID, window: desktopWindow, client: activeClientContext.client)
        try await ensureDesktopStreamStartupCanContinue(
            streamID: activation.streamID,
            clientSessionID: activation.clientContext.sessionID,
            startupRequestID: activation.startupRequestID,
            mode: activation.mode,
            stage: "after input cache registration"
        )
        if let token = virtualDisplaySetupGuardToken {
            await completeVirtualDisplaySetupGuard(token, reason: "desktop_stream_start")
            virtualDisplaySetupGuardToken = nil
        }

        await PowerAssertionManager.shared.enable()
        return excludedWindows
    }

    /// Opens the Loom video stream used by desktop media packets.
    func openDesktopVideoStream(
        streamID: StreamID,
        activeClientContext: ClientContext,
        mode: MirageDesktopStreamMode,
        startupRequestID: UUID
    ) async throws -> LoomMultiplexedStream {
        do {
            let openedVideoStream = try await activeClientContext.controlChannel.session.openStream(
                label: "video/\(streamID)"
            )
            loomVideoStreamsByStreamID[streamID] = openedVideoStream
            transportRegistry.registerVideoStream(openedVideoStream, streamID: streamID)
            MirageLogger.host("Opened Loom video stream for desktop stream \(streamID)")
            try await ensureDesktopStreamStartupCanContinue(
                streamID: streamID,
                clientSessionID: activeClientContext.sessionID,
                startupRequestID: startupRequestID,
                mode: mode,
                stage: "after video stream open"
            )
            return openedVideoStream
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to open Loom video stream for desktop stream \(streamID): "
            )
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            throw error
        }
    }

    /// Starts desktop display capture and retries without audio if capture startup fails.
    func startDesktopDisplayCapture(
        _ activation: DesktopStreamActivation,
        activeVideoStream: LoomMultiplexedStream,
        mediaSendProfile: LoomQueuedUnreliableSendProfile,
        excludedWindows: [SCWindowWrapper],
        audioConfiguration: inout MirageAudioConfiguration
    ) async throws {
        let firstSuccessfulVideoPacketSent = Locked(false)
        let mediaSendProfileReference = await activation.streamContext.setMediaSendProfile(
            mediaSendProfile,
            diagnosticsProvider: { profile in
                await activeVideoStream.consumeQueuedUnreliableSendDiagnostics(profile: profile)
            }
        )
        let startDesktopDisplay: () async throws -> Void = {
            try await activation.streamContext.startDesktopDisplay(
                displayWrapper: activation.captureDisplay,
                resolution: activation.captureResolution,
                excludedWindows: excludedWindows,
                sendPacketWithMetadata: { packetData, metadata, onComplete in
                    let activeMediaSendProfile = mediaSendProfileReference.read { $0 }
                    activeVideoStream.sendUnreliableQueued(
                        packetData,
                        profile: activeMediaSendProfile,
                        options: metadata.loomQueuedUnreliableSendOptions
                    ) { error in
                        if error == nil {
                            self.markDesktopFirstVideoPacketIfNeeded(
                                streamID: activation.streamID,
                                marker: firstSuccessfulVideoPacketSent
                            )
                        }
                        onComplete(error)
                    }
                },
                onSendError: { [weak self] error in
                    guard let self else { return }
                    dispatchMainWork {
                        await self.handleVideoSendError(streamID: activation.streamID, error: error)
                    }
                }
            )
            MirageLogger.host(
                "event=media_path_policy phase=desktop_activation stream=\(activation.streamID) " +
                    "resolved=\(activation.streamContext.transportPathKind.rawValue)/" +
                    "\(activation.streamContext.mediaPathProfile.rawValue) " +
                    "videoTransport=unreliableQueued " +
                    "sendProfile=\(mediaSendProfile.rawValue) maxPacket=\(activation.streamContext.mediaMaxPacketSize)"
            )
        }

        do {
            try await startDesktopDisplay()
        } catch {
            guard audioConfiguration.enabled else { throw error }
            MirageLogger.host(
                "Desktop display capture start failed with audio enabled; retrying without audio: " +
                    "\(error.localizedDescription)"
            )
            audioConfiguration.enabled = false
            audioConfigurationByClientID[activation.clientContext.client.id] = audioConfiguration
            await stopAudioPipeline(for: activation.clientContext.client.id, reason: .error)
            await closeAudioTransportIfNeeded(for: activation.clientContext.client.id)
            await activation.streamContext.setCapturedAudioHandler(nil)
            try await startDesktopDisplay()
        }
    }

    /// Marks the desktop stream once its first video packet is queued successfully.
    nonisolated func markDesktopFirstVideoPacketIfNeeded(
        streamID: StreamID,
        marker: Locked<Bool>
    ) {
        let shouldMarkFirstPacket = marker.withLock { didMark in
            guard !didMark else { return false }
            didMark = true
            return true
        }
        guard shouldMarkFirstPacket else { return }
        Task {
            await HostDesktopStreamTerminationTracker.shared.markDesktopStreamFirstPacketSent(
                streamID: streamID
            )
        }
    }

    /// Waits for desktop capture to produce a usable startup frame, with one recovery retry.
    func waitForDesktopCaptureStartupReadiness(
        streamContext: StreamContext,
        mode: MirageDesktopStreamMode,
        clientID: UUID,
        audioConfiguration: MirageAudioConfiguration
    )
    async throws -> MirageAudioConfiguration {
        guard mode == .unified || mode == .secondary else { return audioConfiguration }

        var effectiveAudioConfiguration = audioConfiguration
        var recoveryAttempted = false
        var audioReadinessFallbackAttempted = false
        while true {
            var readiness = await streamContext.waitForDisplayStartupReadiness(
                timeout: desktopStartupCaptureReadinessWindow
            )
            let capturedStartupSeedFrame: Bool
            if readiness == .noScreenSamples {
                capturedStartupSeedFrame = await streamContext.seedDisplayStartupFrameIfNeeded()
                if !capturedStartupSeedFrame {
                    readiness = await streamContext.waitForDisplayStartupReadiness(
                        timeout: .milliseconds(250)
                    )
                }
            } else {
                capturedStartupSeedFrame = false
            }

            let hasCachedStartupFrame = await streamContext.hasCachedStartupFrame
            let hasObservedStartupSample = await streamContext.hasObservedDisplayStartupSample()
            let canProceedWithoutLiveSample = readiness == .noScreenSamples &&
                (hasCachedStartupFrame || hasObservedStartupSample)
            if readiness == .usableFrameSeen ||
                readiness == .idleFrameSeen ||
                canProceedWithoutLiveSample {
                logDesktopCaptureReadinessAccepted(
                    readiness: readiness,
                    cachedSeed: capturedStartupSeedFrame || hasCachedStartupFrame,
                    observedSample: hasObservedStartupSample
                )
                return effectiveAudioConfiguration
            }

            if !recoveryAttempted {
                recoveryAttempted = true
                MirageLogger.host(
                    "Desktop start: capture readiness \(readiness.rawValue); restarting display capture once"
                )
                await streamContext.restartDisplayCaptureForStartupRecovery(
                    reason: "startup_capture_readiness_\(readiness.rawValue)"
                )
                continue
            }

            if effectiveAudioConfiguration.enabled, !audioReadinessFallbackAttempted {
                audioReadinessFallbackAttempted = true
                effectiveAudioConfiguration.enabled = false
                audioConfigurationByClientID[clientID] = effectiveAudioConfiguration
                MirageLogger.host(
                    "Desktop start: capture readiness \(readiness.rawValue); retrying startup readiness without audio"
                )
                await stopAudioPipeline(for: clientID, reason: .error)
                await closeAudioTransportIfNeeded(for: clientID)
                await streamContext.setCapturedAudioHandler(nil)
                await streamContext.restartDisplayCaptureForStartupRecovery(
                    reason: "startup_capture_readiness_audio_fallback_\(readiness.rawValue)"
                )
                recoveryAttempted = false
                continue
            }
            throw MirageError.protocolError(
                "\(mode.displayName) desktop startup failed waiting for first display sample (\(readiness.rawValue))"
            )
        }
    }

    /// Logs the capture readiness state accepted for desktop startup.
    nonisolated func logDesktopCaptureReadinessAccepted(
        readiness: DisplayCaptureStartupReadiness,
        cachedSeed: Bool,
        observedSample: Bool
    ) {
        if readiness == .noScreenSamples {
            MirageLogger.host(
                "Desktop start: proceeding without a live startup frame " +
                    "(cachedSeed=\(cachedSeed), observedSample=\(observedSample))"
            )
        } else {
            MirageLogger.host(
                "Desktop start: capture readiness satisfied (\(readiness.rawValue))"
            )
        }
    }
}

extension StreamPacketSender.TransportPacketMetadata {
    var loomQueuedUnreliableSendOptions: LoomQueuedUnreliableSendOptions {
        let importance: LoomQueuedUnreliableSendOptions.Importance = if isKeyframe {
            .realtimeKeyframe
        } else if isParity {
            .realtimeParity
        } else if isRecovery {
            .realtimeRecovery
        } else {
            .realtimeInterFrame
        }
        let preservesLowMotionRampFrame = deliveryMode == .lowMotionRamp && !isKeyframe
        let dropsWhenQueueFull = !isKeyframe && !isRecovery && !preservesLowMotionRampFrame
        return LoomQueuedUnreliableSendOptions(
            deadlineUptime: loomDeadlineUptime,
            importance: importance,
            frameID: loomFrameID,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            dropsWhenExpired: dropsWhenExpired,
            dropsWhenQueueFull: dropsWhenQueueFull
        )
    }

    private var loomFrameID: UInt64 {
        (UInt64(streamID) << 32) | UInt64(frameNumber)
    }

    private var loomDeadlineUptime: TimeInterval? {
        guard sendDeadline.isFinite else { return nil }
        let remainingSeconds = sendDeadline - CFAbsoluteTimeGetCurrent()
        return ProcessInfo.processInfo.systemUptime + remainingSeconds
    }
}

#endif
