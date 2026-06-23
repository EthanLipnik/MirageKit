//
//  MirageHostService+AppAtlasCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Removes a logical app-atlas window and tears down the shared media stream when it becomes idle.
    func stopAppAtlasWindow(streamID: StreamID, clientID: UUID) async {
        guard let coordinator = appAtlasCoordinatorsByClientID[clientID] else { return }
        await coordinator.removeWindow(streamID: streamID)
        if await coordinator.isEmpty {
            await stopAppAtlasCoordinator(clientID: clientID)
        }
    }

    /// Stops the app-atlas media coordinator and optionally stops all logical sessions attached to it.
    func stopAppAtlasCoordinator(clientID: UUID, stopLogicalSessions: Bool = false) async {
        appAtlasCoordinatorCreationClientIDs.remove(clientID)

        if stopLogicalSessions, let coordinator = appAtlasCoordinatorsByClientID[clientID] {
            let logicalStreamIDs = await coordinator.logicalStreamIDs()
            let logicalStreamIDSet = Set(logicalStreamIDs)
            let logicalSessions = activeStreams.filter { session in
                session.client.id == clientID && logicalStreamIDSet.contains(session.id)
            }
            let activeLogicalStreamIDs = Set(logicalSessions.map(\.id))
            for session in logicalSessions {
                await stopStream(
                    session,
                    minimizeWindow: false,
                    updateAppSession: true,
                    triggeredByExplicitStreamStop: false
                )
            }
            for streamID in logicalStreamIDs where !activeLogicalStreamIDs.contains(streamID) {
                if appAtlasCoordinatorsByClientID[clientID] != nil {
                    await coordinator.removeWindow(streamID: streamID)
                }
            }
        }

        guard let coordinator = appAtlasCoordinatorsByClientID.removeValue(forKey: clientID) else { return }
        let mediaStreamID = coordinator.mediaStreamID
        cancelPendingStartupAttempt(streamID: mediaStreamID)
        await coordinator.stop()
        streamsByID.removeValue(forKey: mediaStreamID)
        mediaPathClientEvidenceByStreamID.removeValue(forKey: mediaStreamID)
        await deactivateAudioSourceIfNeeded(streamID: mediaStreamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: mediaStreamID) {
            closeRemovedMediaStream(videoStream, streamID: mediaStreamID, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: mediaStreamID)
        await teardownSharedAppStreamMirroringIfIdle(displayID: nil)
        MirageLogger.host("Stopped app-atlas media stream \(mediaStreamID) for client \(clientID.uuidString)")
    }

    /// Returns an existing app-atlas coordinator or creates the shared media stream that backs one.
    func ensureAppAtlasCoordinator(
        clientContext: ClientContext,
        selectRequest: SelectAppMessage,
        targetFrameRate: Int,
        requestedBitrate: Int?,
        mediaMaxPacketSize: Int
    ) async throws -> AppAtlasMediaCoordinator {
        let clientID = clientContext.client.id
        guard !disconnectingClientIDs.contains(clientID) else {
            throw MirageError.protocolError("Client is disconnecting")
        }
        if let existing = appAtlasCoordinatorsByClientID[clientID] {
            try await retuneAppAtlasCoordinator(
                existing,
                selectRequest: selectRequest,
                requestedBitrate: requestedBitrate
            )
            return existing
        }

        if appAtlasCoordinatorCreationClientIDs.contains(clientID) {
            MirageLogger.host(
                "Waiting for in-flight app-atlas coordinator setup for client \(clientID.uuidString)"
            )
            while appAtlasCoordinatorCreationClientIDs.contains(clientID) {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    throw error
                }
                if let existing = appAtlasCoordinatorsByClientID[clientID] {
                    try await retuneAppAtlasCoordinator(
                        existing,
                        selectRequest: selectRequest,
                        requestedBitrate: requestedBitrate
                    )
                    return existing
                }
            }
            if let existing = appAtlasCoordinatorsByClientID[clientID] {
                try await retuneAppAtlasCoordinator(
                    existing,
                    selectRequest: selectRequest,
                    requestedBitrate: requestedBitrate
                )
                return existing
            }
            guard !disconnectingClientIDs.contains(clientID) else {
                throw MirageError.protocolError("Client is disconnecting")
            }
        }

        appAtlasCoordinatorCreationClientIDs.insert(clientID)
        defer {
            appAtlasCoordinatorCreationClientIDs.remove(clientID)
        }

        if let existing = appAtlasCoordinatorsByClientID[clientID] {
            try await retuneAppAtlasCoordinator(
                existing,
                selectRequest: selectRequest,
                requestedBitrate: requestedBitrate
            )
            return existing
        }
        guard !disconnectingClientIDs.contains(clientID) else {
            throw MirageError.protocolError("Client is disconnecting")
        }

        guard mediaSecurityByClientID[clientID] != nil else {
            throw MirageError.protocolError("Missing media security context for client")
        }

        do {
            _ = try await ensureSharedAppStreamMirroring(
                preset: selectRequest.sizePreset ?? .standard,
                refreshRate: targetFrameRate,
                colorSpace: selectRequest.colorDepth?.colorSpace ?? encoderConfig.colorSpace
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "App-atlas shared display backing unavailable; continuing with direct capture: ")
        }

        let mediaStreamID = nextStreamID
        nextStreamID += 1
        var retainMediaPathClientEvidence = false
        defer {
            if !retainMediaPathClientEvidence {
                mediaPathClientEvidenceByStreamID.removeValue(forKey: mediaStreamID)
            }
        }

        var atlasEncoderConfig = resolveEncoderConfiguration(
            keyFrameInterval: selectRequest.keyFrameInterval,
            targetFrameRate: targetFrameRate,
            colorDepth: selectRequest.colorDepth,
            captureQueueDepth: selectRequest.captureQueueDepth,
            bitrate: requestedBitrate ?? selectRequest.bitrate,
            upscalingMode: nil,
            codec: selectRequest.codec
        )
        atlasEncoderConfig = atlasEncoderConfig.withInternalOverrides(pixelFormat: .bgra8)

        let latencyMode = selectRequest.latencyMode ?? .lowestLatency
        let hostBufferingPolicy = selectRequest.resolvedHostBufferingPolicy
        let hostBufferDepth = selectRequest.resolvedHostBufferDepth
        let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline
        let audioConfiguration = selectRequest.audioConfiguration ?? audioConfigurationByClientID[clientID] ?? .default
        let mediaPathPolicy = effectiveMediaPathPolicy(for: selectRequest, clientContext: clientContext)
        mediaPathClientEvidenceByStreamID[mediaStreamID] = HostStreamMediaPathClientEvidence(
            policy: mediaPathPolicy
        )
        let context = StreamContext(
            streamID: mediaStreamID,
            windowID: 0,
            streamKind: .appAtlas,
            encoderConfig: atlasEncoderConfig,
            streamScale: 1.0,
            requestedAudioChannelCount: audioConfiguration.channelLayout.channelCount,
            maxPacketSize: mediaMaxPacketSize,
            mediaSecurityContext: nil,
            runtimeQualityAdjustmentEnabled: selectRequest.allowRuntimeQualityAdjustment ?? true,
            encoderCatchUpQualityAdjustmentEnabled: selectRequest.allowEncoderCatchUpQualityAdjustment ?? true,
            disableResolutionCap: true,
            encoderLowPowerEnabled: isEncoderLowPowerModeActive,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            hostBufferDepth: hostBufferDepth,
            transportPathKind: mediaPathPolicy.transportPathKind,
            mediaPathProfile: mediaPathPolicy.mediaPathProfile,
            mediaPathDiagnosticSummary: mediaPathPolicy.diagnosticSummary,
            enteredBitrate: selectRequest.enteredBitrate,
            bitrateAdaptationCeiling: selectRequest.bitrateAdaptationCeiling,
            compressionQualityCeiling: selectRequest.compressionQualityCeiling,
            encoderMaxWidth: selectRequest.encoderMaxWidth,
            encoderMaxHeight: selectRequest.encoderMaxHeight
        )
        MirageLogger.host(
            "event=media_path_policy phase=app_atlas_start stream=\(mediaStreamID) " +
                "\(mediaPathPolicy.diagnosticSummary) videoTransport=unreliableQueued " +
                "maxPacket=\(mediaMaxPacketSize)"
        )
        streamsByID[mediaStreamID] = context

        await context.setMetricsUpdateHandler { [weak self] metrics in
            self?.recordClientMediaActivity(clientID: clientContext.client.id)
            self?.dispatchControlWork(clientID: clientContext.client.id) { [weak self] in
                guard let self else { return }
                guard let currentClientContext = findClientContext(sessionID: clientContext.sessionID) else { return }
                do {
                    try await currentClientContext.send(.streamMetricsUpdate, content: metrics)
                } catch {
                    await handleControlChannelSendFailure(
                        client: currentClientContext.client,
                        error: error,
                        operation: "App atlas stream metrics",
                        sessionID: clientContext.sessionID
                    )
                }
            }
        }

        do {
            try await activateAudioForClient(
                clientID: clientID,
                expectedSessionID: clientContext.sessionID,
                sourceStreamID: mediaStreamID,
                configuration: audioConfiguration
            )
            cancelAudioFirstSampleWatchdog(for: clientID)
            await PowerAssertionManager.shared.enable()
        } catch {
            streamsByID.removeValue(forKey: mediaStreamID)
            throw error
        }

        let videoStream: LoomMultiplexedStream
        do {
            let openedVideoStream = try await clientContext.controlChannel.session.openStream(
                label: "video/\(mediaStreamID)"
            )
            videoStream = openedVideoStream
            loomVideoStreamsByStreamID[mediaStreamID] = openedVideoStream
            transportRegistry.registerVideoStream(openedVideoStream, streamID: mediaStreamID)
            MirageLogger.host("Opened Loom app-atlas video stream \(mediaStreamID)")
        } catch {
            streamsByID.removeValue(forKey: mediaStreamID)
            await deactivateAudioSourceIfNeeded(streamID: mediaStreamID)
            throw error
        }

        let mediaSendProfile = await clientContext.controlChannel.session.mirageMediaSendProfile(
            resolvedMediaPathProfile: mediaPathPolicy.mediaPathProfile,
            streamID: mediaStreamID,
            phase: "app_atlas_transport"
        )
        let mediaSendProfileReference = await context.setMediaSendProfile(
            mediaSendProfile,
            diagnosticsProvider: { profile in
                await videoStream.consumeQueuedUnreliableSendDiagnostics(profile: profile)
            }
        )
        MirageLogger.host(
            "event=media_path_policy phase=app_atlas_transport stream=\(mediaStreamID) " +
                "\(mediaPathPolicy.diagnosticSummary) videoTransport=unreliableQueued " +
                "sendProfile=\(mediaSendProfile.rawValue) maxPacket=\(context.mediaMaxPacketSize)"
        )
        let coordinator = AppAtlasMediaCoordinator(
            mediaStreamID: mediaStreamID,
            context: context,
            encoderConfig: atlasEncoderConfig,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            capturePressureProfile: capturePressureProfile,
            targetFrameRate: targetFrameRate,
            sendPacketWithMetadata: { packetData, metadata, onComplete in
                let activeMediaSendProfile = mediaSendProfileReference.read { $0 }
                videoStream.sendUnreliableQueued(
                    packetData,
                    profile: activeMediaSendProfile,
                    options: metadata.loomQueuedUnreliableSendOptions,
                    onComplete: onComplete
                )
            },
            onSendError: { [weak self] error in
                guard let self else { return }
                dispatchMainWork {
                    await self.handleVideoSendError(streamID: mediaStreamID, error: error)
                }
            },
            sendMediaUpdate: { [weak self] update in
                guard let self else { return }
                do {
                    try await clientContext.send(.appAtlasMediaUpdate, content: update)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "App atlas media update",
                        sessionID: clientContext.sessionID
                    )
                }
            },
            publishOverlayRegions: { [weak self] streamID, regions in
                guard let self else { return }
                inputStreamCache.setAuxiliaryOverlayRegions(streamID, regions: regions)
            }
        )
        appAtlasCoordinatorsByClientID[clientContext.client.id] = coordinator
        if audioConfiguration.enabled,
           audioSourceStreamByClientID[clientID] == mediaStreamID {
            await setAudioSourceCaptureHandler(clientID: clientID, streamID: mediaStreamID)
        }
        retainMediaPathClientEvidence = true
        return coordinator
    }

    private func retuneAppAtlasCoordinator(
        _ coordinator: AppAtlasMediaCoordinator,
        selectRequest: SelectAppMessage,
        requestedBitrate: Int?
    ) async throws {
        try await coordinator.updateQualityContract(
            bitrate: requestedBitrate ?? selectRequest.bitrate,
            bitrateAdaptationCeiling: selectRequest.bitrateAdaptationCeiling,
            compressionQualityCeiling: selectRequest.compressionQualityCeiling,
            runtimeQualityAdjustmentEnabled: selectRequest.allowRuntimeQualityAdjustment,
            encoderCatchUpQualityAdjustmentEnabled: selectRequest.allowEncoderCatchUpQualityAdjustment
        )
    }
}
#endif
