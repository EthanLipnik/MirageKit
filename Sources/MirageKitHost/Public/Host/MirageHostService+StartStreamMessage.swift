//
//  MirageHostService+MirageWire.StartStreamMessage.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Decodes and validates an app-window stream request before starting capture for the selected window.
    func handleStartStreamMessage(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(MirageWire.StartStreamMessage.self)
            guard !disconnectingClientIDs.contains(clientContext.client.id),
                  clientsByID[clientContext.client.id] != nil else {
                MirageLogger.host("Ignoring startStream from disconnected client \(clientContext.client.name)")
                return
            }
            MirageLogger.host("Client requested stream for window \(request.windowID)")

            await refreshSessionStateIfNeeded()
            guard mirageSessionAvailability == .ready else {
                MirageLogger.host("Rejecting startStream while session is \(mirageSessionAvailability.rawValue)")
                await sendSessionState(to: clientContext)
                return
            }

            guard let window = availableWindows.first(where: { $0.id == request.windowID }) else {
                MirageLogger.host("Window not found: \(request.windowID)")
                sendControlError(
                    .windowNotFound,
                    message: "Window \(request.windowID) not found",
                    to: clientContext
                )
                return
            }

            guard let displayWidth = request.displayWidth,
                  let displayHeight = request.displayHeight,
                  displayWidth > 0,
                  displayHeight > 0 else {
                MirageLogger.host("Rejecting startStream without display size for window \(request.windowID)")
                sendControlError(
                    .invalidMessage,
                    message: "startStream requires displayWidth/displayHeight",
                    to: clientContext
                )
                return
            }
            let clientDisplayResolution = CGSize(width: displayWidth, height: displayHeight)
            MirageLogger.host("Client display size (points): \(displayWidth)x\(displayHeight)")

            let targetFrameRate = resolvedTargetFrameRate(request.targetFrameRate)
            let latencyMode = request.latencyMode ?? .lowestLatency
            let hostBufferingPolicy = request.resolvedHostBufferingPolicy
            let hostBufferDepth = request.resolvedHostBufferDepth
            let disableResolutionCap = request.disableResolutionCap ?? false
            let requestedScale = request.streamScale ?? 1.0
            let audioConfiguration = request.audioConfiguration ?? .default
            let mediaPathPolicy = effectiveMediaPathPolicy(for: request, clientContext: clientContext)
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                mediaPathProfile: mediaPathPolicy.mediaPathProfile,
                pathKind: mediaPathPolicy.transportPathKind
            )
            MirageLogger.host("Frame rate: \(targetFrameRate)fps")
            MirageLogger.host("Latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Host buffering policy: \(hostBufferingPolicy.rawValue)")
            MirageLogger.host("Host buffer depth: \(hostBufferDepth.rawValue)")

            pendingLightsOutSetup = true
            await beginPendingAppStreamLightsOutSetup()
            try await startStreamWithResolvedMediaPath(
                for: window,
                to: clientContext.client,
                expectedSessionID: clientContext.sessionID,
                clientDisplayResolution: clientDisplayResolution,
                clientScaleFactor: request.scaleFactor,
                keyFrameInterval: request.keyFrameInterval,
                streamScale: requestedScale,
                targetFrameRate: targetFrameRate,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                bitrate: request.bitrate,
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                hostBufferDepth: hostBufferDepth,
                allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
                disableResolutionCap: disableResolutionCap,
                audioConfiguration: audioConfiguration,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                compressionQualityCeiling: request.compressionQualityCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                mediaPathPolicy: mediaPathPolicy,
                upscalingMode: request.upscalingMode,
                codec: request.codec
            )
            pendingLightsOutSetup = false
            await endPendingAppStreamLightsOutSetup()
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingAppStreamLightsOutSetup()
            }
            MirageLogger.error(.host, error: error, message: "Failed to handle startStream: ")
            let errorCode: MirageWire.ErrorMessage.ErrorCode = if error is WindowStreamStartError {
                .virtualDisplayStartFailed
            } else {
                .encodingError
            }
            sendControlError(
                errorCode,
                message: "Failed to start stream: \(error.localizedDescription)",
                to: clientContext
            )
        }
    }
}
#endif
