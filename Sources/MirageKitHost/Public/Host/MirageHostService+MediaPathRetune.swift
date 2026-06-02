//
//  MirageHostService+MediaPathRetune.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/2/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    func startMediaPathObserver(clientContext: ClientContext) {
        mediaPathObserverTasksBySessionID[clientContext.sessionID]?.cancel()

        let sessionID = clientContext.sessionID
        let clientID = clientContext.client.id
        let session = clientContext.controlChannel.session
        mediaPathObserverTasksBySessionID[sessionID] = Task.detached(priority: .userInitiated) { [weak self, session] in
            let observer = await session.makePathObserver()
            var lastSignature: String?
            for await pathSnapshot in observer {
                guard !Task.isCancelled else { break }
                let classifiedSnapshot = MirageNetworkPathClassifier.classify(pathSnapshot)
                guard classifiedSnapshot.signature != lastSignature else { continue }
                lastSignature = classifiedSnapshot.signature
                await self?.handleMediaPathSnapshotUpdate(
                    sessionID: sessionID,
                    clientID: clientID,
                    hostSnapshot: classifiedSnapshot
                )
            }
        }
    }

    func stopMediaPathObserver(sessionID: UUID) {
        mediaPathObserverTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
    }

    func handleMediaPathSnapshotUpdate(
        sessionID: UUID,
        clientID: UUID,
        hostSnapshot: MirageNetworkPathSnapshot
    ) async {
        guard let clientContext = clientsBySessionID[sessionID],
              clientContext.client.id == clientID else {
            return
        }
        guard hostSnapshot.mediaProfile != .unknown || hostSnapshot.kind != .unknown else {
            return
        }

        MirageLogger.host(
            "event=media_path_policy phase=host_path_update session=\(sessionID.uuidString) " +
                "\(hostSnapshot.signature)"
        )
        await retuneActiveMediaSendProfiles(
            clientContext: clientContext,
            hostSnapshot: hostSnapshot
        )
    }

    func retuneActiveMediaSendProfiles(
        clientContext: ClientContext,
        hostSnapshot: MirageNetworkPathSnapshot
    ) async {
        for (streamID, context) in activeMediaContexts(for: clientContext) {
            guard let videoStream = loomVideoStreamsByStreamID[streamID] else { continue }
            let policy = effectiveMediaPathPolicyForActiveMediaRetune(
                hostSnapshot: hostSnapshot,
                streamID: streamID
            )
            let newProfile = await clientContext.controlChannel.session.mirageMediaSendProfile(
                resolvedMediaPathProfile: policy.mediaPathProfile,
                streamID: streamID,
                phase: "host_path_update"
            )
            let oldProfile = await context.activeMediaSendProfile()
            let pipelineClassChanged = context.mediaPathProfile.usesAwdlRadioPolicy !=
                policy.mediaPathProfile.usesAwdlRadioPolicy
            guard oldProfile != newProfile || pipelineClassChanged else { continue }

            if oldProfile != newProfile {
                _ = await context.setMediaSendProfile(
                    newProfile,
                    diagnosticsProvider: { profile in
                        await videoStream.consumeQueuedUnreliableSendDiagnostics(profile: profile)
                    }
                )
                await videoStream.resetQueuedUnreliableSends(profile: oldProfile)
                await videoStream.resetQueuedUnreliableSends(profile: newProfile)
            }

            if pipelineClassChanged {
                let restartedDesktopPipeline = await restartDesktopMediaPipelineForRouteClassChange(
                    clientContext: clientContext,
                    streamID: streamID,
                    previousContext: context,
                    activeVideoStream: videoStream,
                    policy: policy,
                    mediaSendProfile: newProfile
                )
                if !restartedDesktopPipeline {
                    _ = await context.scheduleCoalescedRecoveryKeyframe(
                        reason: "media-path-retune",
                        noteLoss: policy.mediaPathProfile.usesAwdlRadioPolicy,
                        ignoreExistingInFlight: true,
                        bypassesRecoveryCooldown: true
                    )
                    await sendTransportRefreshRequest(
                        streamID: streamID,
                        reason: "media-path-retune"
                    )
                }
            }

            MirageLogger.host(
                "event=media_path_policy phase=host_path_retune stream=\(streamID) " +
                    "\(policy.diagnosticSummary) oldSendProfile=\(oldProfile.rawValue) " +
                    "newSendProfile=\(newProfile.rawValue) " +
                    "pipelineClassChanged=\(pipelineClassChanged)"
            )
        }
    }

    func effectiveMediaPathPolicyForActiveMediaRetune(
        hostSnapshot: MirageNetworkPathSnapshot,
        streamID: StreamID
    ) -> MirageEffectiveMediaPathPolicy {
        let clientEvidence = mediaPathClientEvidenceByStreamID[streamID]
        return MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: clientEvidence?.pathKind,
            clientMediaPathProfile: clientEvidence?.mediaPathProfile,
            clientPathSignature: clientEvidence?.pathSignature
        )
    }

    private func activeMediaContexts(for clientContext: ClientContext) -> [(StreamID, StreamContext)] {
        streamsByID.compactMap { streamID, context in
            if desktopStreamID == streamID,
               desktopStreamClientContext?.sessionID == clientContext.sessionID {
                return (streamID, context)
            }
            if let session = activeSessionByStreamID[streamID],
               session.client.id == clientContext.client.id {
                return (streamID, context)
            }
            if customStreamClientSessionIDByStreamID[streamID] == clientContext.sessionID {
                return (streamID, context)
            }
            return nil
        }
    }

    private func restartDesktopMediaPipelineForRouteClassChange(
        clientContext: ClientContext,
        streamID: StreamID,
        previousContext: StreamContext,
        activeVideoStream: LoomMultiplexedStream,
        policy: MirageEffectiveMediaPathPolicy,
        mediaSendProfile: LoomQueuedUnreliableSendProfile
    ) async -> Bool {
        guard streamID == desktopStreamID,
              desktopStreamClientContext?.sessionID == clientContext.sessionID,
              desktopStreamClientContext?.client.id == clientContext.client.id,
              let desktopSessionID,
              desktopMediaPathPipelineRestartStreamID == nil else {
            return false
        }

        desktopMediaPathPipelineRestartStreamID = streamID
        defer {
            if desktopMediaPathPipelineRestartStreamID == streamID {
                desktopMediaPathPipelineRestartStreamID = nil
            }
        }

        let restartStart = CFAbsoluteTimeGetCurrent()
        func logRestartStep(_ step: String) {
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - restartStart) * 1000)
            MirageLogger.host("Desktop media pipeline restart: \(step) (+\(deltaMs)ms)")
        }

        var replacementContextForCleanup: StreamContext?
        var committedReplacement = false
        var stoppedPreviousContext = false

        do {
            let restartSnapshot = await previousContext.desktopPipelineRestartSnapshot
            let previousStartSnapshot = await previousContext.streamStartSnapshot
            let captureContext = try await currentDesktopCaptureContextForMediaPipelineRestart(
                fallbackEncodedSize: previousStartSnapshot.encodedDimensions
            )
            let activeAudioConfiguration = audioConfigurationByClientID[clientContext.client.id] ??
                MirageAudioConfiguration(enabled: false)
            let replacementMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: previousStartSnapshot.mediaMaxPacketSize,
                mediaPathProfile: policy.mediaPathProfile,
                pathKind: policy.transportPathKind
            )
            let replacementContext = await makeDesktopStreamContext(
                DesktopStreamContextRequest(
                    streamID: streamID,
                    config: restartSnapshot.encoderConfig,
                    streamScale: restartSnapshot.requestedStreamScale,
                    audioConfiguration: activeAudioConfiguration,
                    mediaMaxPacketSize: replacementMediaMaxPacketSize,
                    allowRuntimeQualityAdjustment: restartSnapshot.runtimeQualityAdjustmentEnabled,
                    allowEncoderCatchUpQualityAdjustment: restartSnapshot.encoderCatchUpQualityAdjustmentEnabled,
                    lowLatencyHighResolutionCompressionBoost: restartSnapshot.lowLatencyHighResolutionCompressionBoostEnabled,
                    disableResolutionCap: restartSnapshot.disableResolutionCap,
                    capturePressureProfile: restartSnapshot.capturePressureProfile,
                    latencyMode: restartSnapshot.requestedLatencyMode,
                    hostBufferingPolicy: restartSnapshot.requestedHostBufferingPolicy,
                    transportPathKind: policy.transportPathKind,
                    mediaPathProfile: policy.mediaPathProfile,
                    enteredBitrate: restartSnapshot.explicitEnteredBitrate ?? restartSnapshot.enteredBitrate,
                    bitrateAdaptationCeiling: restartSnapshot.bitrateAdaptationCeiling,
                    encoderMaxWidth: restartSnapshot.encoderMaxWidth,
                    encoderMaxHeight: restartSnapshot.encoderMaxHeight,
                    cursorPresentation: desktopCursorPresentation,
                    desktopStartTime: restartStart,
                    captureDisplayP3CoverageStatus: captureContext.p3CoverageStatus ??
                        restartSnapshot.displayP3CoverageStatusOverride,
                    virtualDisplaySnapshot: captureContext.virtualDisplaySnapshot ??
                        restartSnapshot.virtualDisplaySnapshot,
                    usesDisplayRefreshCadence: captureContext.usesDisplayRefreshCadence ??
                        restartSnapshot.usesDisplayRefreshCadence
                )
            )
            await replacementContext.seedReplacementPipelineTokens(
                dimensionToken: restartSnapshot.nextDimensionToken,
                epoch: restartSnapshot.nextEpoch,
                reason: "media-path-route-class-change"
            )
            replacementContextForCleanup = replacementContext

            logRestartStep(
                "replacement context created stream=\(streamID) " +
                    "\(policy.transportPathKind.rawValue)/\(policy.mediaPathProfile.rawValue)"
            )

            await previousContext.suspendEncodingForDesktopResize()

            var effectiveAudioConfiguration = activeAudioConfiguration
            let excludedWindows = await resolveLightsOutExcludedWindows()
            try await startDesktopDisplayCapture(
                DesktopStreamActivation(
                    streamID: streamID,
                    clientContext: clientContext,
                    streamContext: replacementContext,
                    requestedScaleFactor: desktopRequestedScaleFactor ?? sharedVirtualDisplayScaleFactor,
                    audioConfiguration: effectiveAudioConfiguration,
                    mode: desktopStreamMode,
                    startupRequestID: UUID(),
                    captureDisplay: captureContext.display,
                    captureResolution: captureContext.resolution
                ),
                activeVideoStream: activeVideoStream,
                mediaSendProfile: mediaSendProfile,
                excludedWindows: excludedWindows,
                audioConfiguration: &effectiveAudioConfiguration
            )
            audioConfigurationByClientID[clientContext.client.id] = effectiveAudioConfiguration
            logRestartStep("capture restarted")

            _ = try await waitForDesktopCaptureStartupReadiness(
                streamContext: replacementContext,
                mode: desktopStreamMode,
                clientID: clientContext.client.id,
                audioConfiguration: effectiveAudioConfiguration
            )

            guard streamID == desktopStreamID,
                  desktopStreamClientContext?.sessionID == clientContext.sessionID,
                  desktopStreamClientContext?.client.id == clientContext.client.id else {
                throw MirageError.protocolError("Desktop stream owner changed during media pipeline restart")
            }

            await previousContext.stop()
            stoppedPreviousContext = true
            await activeVideoStream.resetQueuedUnreliableSends(profile: mediaSendProfile)
            await configureDesktopMetricsHandler(replacementContext, clientContext: clientContext)
            desktopStreamContext = replacementContext
            streamsByID[streamID] = replacementContext
            committedReplacement = true
            replacementContextForCleanup = nil
            if effectiveAudioConfiguration.enabled {
                await setAudioSourceCaptureHandler(clientID: clientContext.client.id, streamID: streamID)
            }

            let streamStart = await replacementContext.streamStartSnapshot
            let encodedResolution = CGSize(
                width: streamStart.encodedDimensions.width,
                height: streamStart.encodedDimensions.height
            )
            let displayResolution = await currentDesktopStartedResolution(
                fallback: captureContext.resolution
            )
            let geometryContract = reusableCurrentDesktopGeometryContract(
                displayPixelResolution: displayResolution,
                encodedPixelResolution: encodedResolution,
                fallbackLogicalResolution: desktopCurrentGeometryPresentationResolution,
                refreshTargetHz: streamStart.targetFrameRate
            )
            _ = try await sendDesktopStreamStartedNotification(
                DesktopStreamStartedNotification(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID,
                    activeClientContext: clientContext,
                    streamContext: replacementContext,
                    captureResolution: captureContext.resolution,
                    captureSource: desktopCaptureSource,
                    allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
                    presentationResolution: geometryContract.presentationResolution,
                    acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
                    desktopGeometryContractID: geometryContract.contractID,
                    desktopGeometrySceneIdentity: geometryContract.sceneIdentity,
                    desktopGeometryRefreshTargetHz: geometryContract.refreshTargetHz
                ),
                logDesktopStartStep: logRestartStep
            )
            await sendTransportRefreshRequest(streamID: streamID, reason: "media-path-pipeline-restart")
            MirageLogger.host(
                "event=media_path_policy phase=desktop_pipeline_restart stream=\(streamID) " +
                    "\(policy.diagnosticSummary) token=\(streamStart.dimensionToken) " +
                    "sendProfile=\(mediaSendProfile.rawValue)"
            )
            return true
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Desktop media pipeline restart failed after route-class change: "
            )
            if !committedReplacement {
                await replacementContextForCleanup?.stop()
            }
            if stoppedPreviousContext {
                await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
                return true
            }
            await previousContext.resumeEncodingAfterDesktopResize()
            return false
        }
    }

    private func currentDesktopCaptureContextForMediaPipelineRestart(
        fallbackEncodedSize: (width: Int, height: Int)
    ) async throws -> DesktopCaptureContext {
        switch desktopCaptureSource {
        case .mainDisplayFallback:
            let fallback = try await mainDisplayDesktopCaptureFallback(
                reason: "media_path_pipeline_restart"
            )
            return DesktopCaptureContext(
                display: fallback.display,
                resolution: fallback.resolution,
                p3CoverageStatus: nil,
                colorSpace: nil,
                captureSource: .mainDisplayFallback,
                allowsClientResize: false,
                presentationResolution: desktopCurrentGeometryPresentationResolution ??
                    aspectFitPixelSize(
                        contentSize: fallback.resolution,
                        containerSize: fallback.resolution
                    ),
                virtualDisplaySnapshot: nil,
                usesDisplayRefreshCadence: nil,
                acceptedDisplayScaleFactor: fallback.scaleFactor
            )
        case .virtualDisplay:
            let sharedDisplayID = await SharedVirtualDisplayManager.shared.displayID
            guard let displayID = desktopVirtualDisplayID ?? sharedDisplayID else {
                throw MirageError.protocolError("Desktop media pipeline restart missing active virtual display")
            }
            let display = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                displayID: displayID,
                maxAttempts: 8
            )
            let snapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
            let fallbackSize = CGSize(width: fallbackEncodedSize.width, height: fallbackEncodedSize.height)
            let resolution: CGSize
            if let snapshotResolution = snapshot?.resolution {
                resolution = snapshotResolution
            } else {
                resolution = await currentDesktopStartedResolution(fallback: fallbackSize)
            }
            return DesktopCaptureContext(
                display: display,
                resolution: resolution,
                p3CoverageStatus: snapshot?.displayP3CoverageStatus,
                colorSpace: snapshot?.colorSpace,
                captureSource: .virtualDisplay,
                allowsClientResize: true,
                presentationResolution: desktopCurrentGeometryPresentationResolution ??
                    desktopPresentationResolution(
                        displayPixelResolution: resolution,
                        acceptedDisplayScaleFactor: desktopCurrentGeometryDisplayScaleFactor
                    ),
                virtualDisplaySnapshot: snapshot,
                usesDisplayRefreshCadence: true,
                acceptedDisplayScaleFactor: snapshot?.scaleFactor ?? desktopCurrentGeometryDisplayScaleFactor
            )
        }
    }
}
#endif
