//
//  MirageHostService+CustomStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
//

import CoreGraphics
import Foundation
import Loom
import MirageKit

#if os(macOS)

@MainActor
public extension MirageHostService {
    /// Registers or replaces a custom stream source for its descriptor kind.
    func registerCustomStreamSource(_ source: any MirageCustomStreamSource) {
        let kind = source.descriptor.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else {
            MirageLogger.error(.host, "Ignoring custom stream source with empty kind")
            return
        }
        customStreamSourcesByKind[kind] = source
        MirageLogger.host("Registered custom stream source kind=\(kind)")
    }

    /// Removes a registered custom stream source.
    func unregisterCustomStreamSource(kind: String) {
        customStreamSourcesByKind.removeValue(forKey: kind)
    }

    /// Snapshot of registered custom stream descriptors.
    var customStreamDescriptors: [MirageCustomStreamDescriptor] {
        customStreamSourcesByKind.values
            .map(\.descriptor)
            .sorted { lhs, rhs in lhs.kind < rhs.kind }
    }
}

@MainActor
extension MirageHostService {
    func handleStartCustomStream(_ message: ControlMessage, from clientContext: ClientContext) async {
        let request: StartCustomStreamMessage
        do {
            request = try message.decode(StartCustomStreamMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode custom stream start: ")
            return
        }

        do {
            try await startCustomStream(request, to: clientContext)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle custom stream start: ")
            let failed = CustomStreamFailedMessage(
                startupRequestID: request.startupRequestID,
                reason: error.localizedDescription
            )
            do {
                try await clientContext.send(.customStreamFailed, content: failed)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send customStreamFailed: ")
            }
        }
    }

    func handleStopCustomStream(_ message: ControlMessage, from clientContext: ClientContext) async {
        let request: StopCustomStreamMessage
        do {
            request = try message.decode(StopCustomStreamMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle custom stream stop: ")
            return
        }

        guard customStreamClientSessionIDByStreamID[request.streamID] == clientContext.sessionID else {
            return
        }
        await stopCustomStream(
            streamID: request.streamID,
            reason: .clientRequested,
            notifyClient: true
        )
    }

    func startCustomStream(
        _ request: StartCustomStreamMessage,
        to clientContext: ClientContext
    ) async throws {
        guard beginStreamSetup(
            clientSessionID: clientContext.sessionID,
            startupRequestID: request.startupRequestID
        ) else {
            throw MirageError.protocolError("Custom stream startup was cancelled")
        }
        defer {
            finishStreamSetup(
                clientSessionID: clientContext.sessionID,
                startupRequestID: request.startupRequestID
            )
        }

        let kind = request.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else {
            throw MirageError.protocolError("Custom stream kind is required")
        }
        guard let source = customStreamSourcesByKind[kind] else {
            throw MirageError.protocolError("No custom stream source registered for \(kind)")
        }
        guard mediaSecurityByClientID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Missing media security context for custom stream client")
        }
        guard !disconnectingClientIDs.contains(clientContext.client.id),
              clientsByID[clientContext.client.id] != nil else {
            throw MirageError.protocolError("Client is disconnected or disconnecting")
        }

        await cancelQualityTest(
            for: clientContext.client.id,
            reason: "custom stream startup"
        )

        let streamID = nextStreamID
        nextStreamID += 1

        var config = resolveEncoderConfiguration(
            keyFrameInterval: request.keyFrameInterval,
            targetFrameRate: request.targetFrameRate,
            colorDepth: .standard,
            captureQueueDepth: nil,
            bitrate: request.bitrate,
            upscalingMode: request.upscalingMode,
            codec: request.codec
        )
        config = config.withInternalOverrides(pixelFormat: .bgra8)

        let context = StreamContext(
            streamID: streamID,
            windowID: 0,
            streamKind: .custom,
            encoderConfig: config,
            streamScale: request.streamScale ?? 1.0,
            maxPacketSize: mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                pathKind: clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
            ),
            mediaSecurityContext: mediaSecurityByClientID[clientContext.client.id],
            runtimeQualityAdjustmentEnabled: request.allowRuntimeQualityAdjustment ?? true,
            lowLatencyHighResolutionCompressionBoostEnabled: request.lowLatencyHighResolutionCompressionBoost ?? false,
            disableResolutionCap: request.disableResolutionCap ?? false,
            latencyMode: request.latencyMode ?? .balanced,
            hostBufferingPolicy: request.resolvedHostBufferingPolicy,
            transportPathKind: clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind } ?? .unknown,
            bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
            encoderMaxWidth: request.encoderMaxWidth,
            encoderMaxHeight: request.encoderMaxHeight
        )
        streamsByID[streamID] = context
        await context.setStartupBaseTime(CFAbsoluteTimeGetCurrent(), label: "custom stream \(streamID)")

        let videoStream: LoomMultiplexedStream
        do {
            videoStream = try await clientContext.controlChannel.session.openStream(label: "video/\(streamID)")
            loomVideoStreamsByStreamID[streamID] = videoStream
            transportRegistry.registerVideoStream(videoStream, streamID: streamID)
        } catch {
            streamsByID.removeValue(forKey: streamID)
            throw error
        }

        let mediaSendProfile = await clientContext.controlChannel.session.mirageMediaSendProfile()
        let sendPacket: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void = { packetData, onComplete in
            videoStream.sendUnreliableQueued(packetData, profile: mediaSendProfile, onComplete: onComplete)
        }
        let onSendError: @Sendable (Error) -> Void = { [weak self] error in
            guard let self else { return }
            dispatchMainWork {
                await self.handleVideoSendError(streamID: streamID, error: error)
            }
        }

        let frameSink: MirageCustomStreamFrameSink
        do {
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: request.startupRequestID
            ) else {
                throw MirageError.protocolError("Custom stream startup was cancelled")
            }
            frameSink = try await context.startCustomFrameStream(
                pixelSize: CGSize(width: request.displayWidth, height: request.displayHeight),
                sendPacket: sendPacket,
                onSendError: onSendError
            )
        } catch {
            await cleanupFailedCustomStreamStart(streamID: streamID, context: context)
            throw error
        }

        let sourceSession: any MirageCustomStreamSession
        do {
            guard !isStreamSetupCancelled(
                clientSessionID: clientContext.sessionID,
                startupRequestID: request.startupRequestID
            ) else {
                throw MirageError.protocolError("Custom stream startup was cancelled")
            }
            sourceSession = try await source.startStream(
                request: request.publicRequest,
                frameSink: frameSink
            )
        } catch {
            await cleanupFailedCustomStreamStart(streamID: streamID, context: context)
            throw error
        }

        customStreamSessionsByStreamID[streamID] = sourceSession
        customStreamDescriptorsByStreamID[streamID] = source.descriptor
        customStreamClientSessionIDByStreamID[streamID] = clientContext.sessionID
        customStreamStartupRequestIDByStreamID[streamID] = request.startupRequestID
        if let inputHandler = sourceSession.inputHandler {
            streamRegistry.registerCustomInputHandler(streamID: streamID, inputHandler)
        }
        await PowerAssertionManager.shared.enable()

        let streamStart = await context.streamStartSnapshot
        let startupAttemptID = UUID()
        let started = MirageCustomStreamStartedMessage(
            startupRequestID: request.startupRequestID,
            streamID: streamID,
            descriptor: source.descriptor,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            startupAttemptID: startupAttemptID,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
        )

        do {
            registerPendingStartupAttempt(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                sessionID: clientContext.sessionID,
                clientID: clientContext.client.id,
                kind: .custom
            )
            try await clientContext.send(.customStreamStarted, content: started)
            MirageLogger.host("Custom stream started kind=\(kind) stream=\(streamID)")
        } catch {
            cancelPendingStartupAttempt(streamID: streamID)
            await stopCustomStream(streamID: streamID, reason: .error, notifyClient: false)
            throw error
        }
    }

    func stopCustomStream(
        streamID: StreamID,
        reason: MirageCustomStreamStoppedMessage.Reason,
        notifyClient: Bool
    ) async {
        cancelPendingStartupAttempt(streamID: streamID)
        streamRegistry.unregisterCustomInputHandler(streamID: streamID)

        if let sourceSession = customStreamSessionsByStreamID.removeValue(forKey: streamID) {
            await sourceSession.stop()
        }

        if let context = streamsByID.removeValue(forKey: streamID) {
            await context.stop()
        }

        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            closeRemovedMediaStream(videoStream, streamID: streamID, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)

        let clientSessionID = customStreamClientSessionIDByStreamID.removeValue(forKey: streamID)
        customStreamDescriptorsByStreamID.removeValue(forKey: streamID)
        customStreamStartupRequestIDByStreamID.removeValue(forKey: streamID)

        if notifyClient,
           let clientSessionID,
           let clientContext = findClientContext(sessionID: clientSessionID) {
            let stopped = MirageCustomStreamStoppedMessage(streamID: streamID, reason: reason)
            do {
                try await clientContext.send(.customStreamStopped, content: stopped)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send customStreamStopped: ")
            }
        }

        if activeStreams.isEmpty, desktopStreamID == nil, customStreamSessionsByStreamID.isEmpty {
            await PowerAssertionManager.shared.disable()
        }
    }

    private func cleanupFailedCustomStreamStart(
        streamID: StreamID,
        context: StreamContext
    ) async {
        await context.stop()
        streamsByID.removeValue(forKey: streamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            closeRemovedMediaStream(videoStream, streamID: streamID, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
        streamRegistry.unregisterCustomInputHandler(streamID: streamID)
        customStreamSessionsByStreamID.removeValue(forKey: streamID)
        customStreamDescriptorsByStreamID.removeValue(forKey: streamID)
        customStreamClientSessionIDByStreamID.removeValue(forKey: streamID)
        customStreamStartupRequestIDByStreamID.removeValue(forKey: streamID)
    }
}

#endif
