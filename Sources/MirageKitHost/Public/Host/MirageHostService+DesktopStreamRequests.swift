//
//  MirageHostService+DesktopStreamRequests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

/// Returns whether a desktop-stop request still matches the active desktop stream session.
func shouldAcceptStopDesktopStreamRequest(
    requestedStreamID: StreamID,
    requestedDesktopSessionID: UUID,
    activeDesktopStreamID: StreamID?,
    activeDesktopSessionID: UUID?
) -> Bool {
    guard requestedStreamID == activeDesktopStreamID,
          let activeDesktopSessionID else {
        return false
    }

    return requestedDesktopSessionID == activeDesktopSessionID
}

func shouldRejectAwdlDesktopStartupWithoutGeometryContract(
    usesHostResolution: Bool,
    transportPathKind: MirageNetworkPathKind,
    mediaPathProfile: MirageMediaPathProfile,
    desktopGeometryContractID: UUID?
) -> Bool {
    let hasAwdlEvidence = transportPathKind == .awdl || mediaPathProfile.usesAwdlRadioPolicy
    return !usesHostResolution &&
        hasAwdlEvidence &&
        desktopGeometryContractID == nil
}

extension MirageHostService {
    /// Handles a client request to start desktop streaming.
    func handleStartDesktopStream(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        var pendingLightsOutSetup = false
        do {
            let request = try message.decode(StartDesktopStreamMessage.self)
            await cancelQualityTest(
                for: clientContext.client.id,
                reason: "desktop stream startup"
            )
            MirageLogger
                .host(
                    "Client \(clientContext.client.name) requested desktop stream: " +
                        "\(request.displayWidth)x\(request.displayHeight) pts, mode=\(request.mode?.displayName ?? "Unified")"
                )
            let enteredBitrateText = request.enteredBitrate.map(mirageFormattedMegabitRate) ?? "n/a"
            let requestedBitrateText = request.bitrate.map(mirageFormattedMegabitRate) ?? "auto"
            let ceilingText = request.bitrateAdaptationCeiling.map(mirageFormattedMegabitRate) ?? "none"
            MirageLogger.host(
                "Desktop bitrate contract received: entered=\(enteredBitrateText) requested=\(requestedBitrateText) ceiling=\(ceilingText)"
            )

            let targetFrameRate = resolvedTargetFrameRate(request.targetFrameRate)
            MirageLogger.host("Desktop stream frame rate: \(targetFrameRate)fps")
            let latencyMode = request.latencyMode ?? .lowestLatency
            let hostBufferingPolicy = request.resolvedHostBufferingPolicy
            let mediaPathPolicy = await effectiveMediaPathPolicyUsingLiveSession(
                for: request,
                clientContext: clientContext
            )
            let adaptiveFloorFPS = targetFrameRate >= 90 ? 60 : targetFrameRate
            MirageLogger.host(
                "event=cadence_contract phase=host_accept requested=\(request.targetFrameRate) " +
                    "accepted=\(targetFrameRate) source=\(targetFrameRate) display=\(targetFrameRate) " +
                    "adaptiveFloor=\(adaptiveFloorFPS) path=\(mediaPathPolicy.transportPathKind.rawValue) " +
                    "latency=\(latencyMode.rawValue)"
            )
            let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
                requested: request.mediaMaxPacketSize,
                mediaPathProfile: mediaPathPolicy.mediaPathProfile,
                pathKind: mediaPathPolicy.transportPathKind
            )
            MirageLogger.host("Desktop stream latency mode: \(latencyMode.displayName)")
            MirageLogger.host("Desktop stream host buffering policy: \(hostBufferingPolicy.rawValue)")
            let audioConfiguration = request.audioConfiguration ?? .default
            let usesHostResolution = request.useHostResolution == true

            let displayResolution: CGSize = if usesHostResolution {
                Self.hostMainDisplayLogicalResolution()
                    ?? CGSize(width: request.displayWidth, height: request.displayHeight)
            } else {
                CGSize(width: request.displayWidth, height: request.displayHeight)
            }
            if usesHostResolution {
                MirageLogger.host(
                    "Using host display resolution: \(Int(displayResolution.width))x\(Int(displayResolution.height)) pts"
                )
            }
            if shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: usesHostResolution,
                transportPathKind: mediaPathPolicy.transportPathKind,
                mediaPathProfile: mediaPathPolicy.mediaPathProfile,
                desktopGeometryContractID: request.desktopGeometryContractID
            ) {
                throw MirageError.protocolError(
                    "Desktop geometry contract required for AWDL desktop startup"
                )
            }

            guard beginStreamSetup(
                clientSessionID: clientContext.sessionID,
                startupRequestID: request.startupRequestID
            ) else {
                MirageLogger.host("Ignoring cancelled desktop setup before side effects")
                return
            }
            defer {
                finishStreamSetup(
                    clientSessionID: clientContext.sessionID,
                    startupRequestID: request.startupRequestID
                )
            }
            desktopStreamMode = request.mode ?? .unified
            desktopUsesHostResolution = usesHostResolution
            desktopCursorPresentation = request.cursorPresentation ?? .simulatedCursor
            pendingLightsOutSetup = true
            await beginPendingDesktopStreamLightsOutSetup()
            try await startDesktopStream(
                to: clientContext,
                displayResolution: displayResolution,
                clientScaleFactor: request.scaleFactor,
                mode: request.mode ?? .unified,
                cursorPresentation: request.cursorPresentation ?? .simulatedCursor,
                keyFrameInterval: request.keyFrameInterval,
                colorDepth: request.colorDepth,
                captureQueueDepth: request.captureQueueDepth,
                enteredBitrate: request.enteredBitrate,
                bitrate: request.bitrate,
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
                allowEncoderCatchUpQualityAdjustment: request.allowEncoderCatchUpQualityAdjustment,
                lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost ?? false,
                disableResolutionCap: request.disableResolutionCap ?? false,
                streamScale: request.streamScale,
                audioConfiguration: audioConfiguration,
                targetFrameRate: targetFrameRate,
                bitrateAdaptationCeiling: request.bitrateAdaptationCeiling,
                encoderMaxWidth: request.encoderMaxWidth,
                encoderMaxHeight: request.encoderMaxHeight,
                mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                mediaPathPolicy: mediaPathPolicy,
                upscalingMode: request.upscalingMode,
                codec: request.codec,
                startupRequestID: request.startupRequestID,
                desktopGeometryContractID: usesHostResolution ? nil : request.desktopGeometryContractID,
                desktopGeometrySceneIdentity: usesHostResolution ? nil : request.desktopGeometrySceneIdentity,
                desktopGeometryRefreshTargetHz: usesHostResolution ? nil : request.desktopGeometryRefreshTargetHz
            )
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingDesktopStreamLightsOutSetup()
            }
        } catch {
            if pendingLightsOutSetup {
                pendingLightsOutSetup = false
                await endPendingDesktopStreamLightsOutSetup()
            }
            if Self.isExpectedDesktopStartRejection(error) {
                MirageLogger.host("Desktop stream request rejected: \(error.localizedDescription)")
            } else {
                MirageLogger.error(.host, error: error, message: "Failed to handle desktop stream request: ")
            }
            let errorPayload = Self.desktopStartErrorPayload(for: error)
            let failedMessage = DesktopStreamFailedMessage(reason: errorPayload.message)
            do {
                try await clientContext.send(.desktopStreamFailed, content: failedMessage)
            } catch {
                clientContext.queueBestEffort(.error, content: errorPayload)
            }
        }
    }

    /// Handles a client request to stop desktop streaming.
    func handleStopDesktopStream(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StopDesktopStreamMessage.self)
            MirageLogger.host(
                "Client requested stop desktop stream: stream=\(request.streamID), session=\(request.desktopSessionID.uuidString)"
            )

            guard shouldAcceptStopDesktopStreamRequest(
                requestedStreamID: request.streamID,
                requestedDesktopSessionID: request.desktopSessionID,
                activeDesktopStreamID: desktopStreamID,
                activeDesktopSessionID: desktopSessionID
            ) else {
                MirageLogger.host(
                    "Ignoring stale desktop stop request: requestedStream=\(request.streamID), requestedSession=\(request.desktopSessionID.uuidString), activeStream=\(desktopStreamID.map(String.init) ?? "nil"), activeSession=\(desktopSessionID?.uuidString ?? "nil")"
                )
                return
            }

            await stopDesktopStream(reason: .clientRequested)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle stop desktop stream: ")
        }
    }

    /// Handles a client request to cancel in-progress stream setup.
    func handleCancelStreamSetup(_ message: ControlMessage, from clientContext: ClientContext) async {
        let request: CancelStreamSetupMessage
        do {
            request = try message.decode(CancelStreamSetupMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode cancel stream setup request: ")
            return
        }

        MirageLogger.host(
            "Client cancelled stream setup request=\(request.startupRequestID?.uuidString ?? "unscoped") kind=\(request.kind?.rawValue ?? "any")"
        )

        if let startupRequestID = request.startupRequestID {
            cancelStreamSetup(
                clientSessionID: clientContext.sessionID,
                startupRequestID: startupRequestID
            )
        } else {
            cancelAllStreamSetup(clientSessionID: clientContext.sessionID)
        }

        if request.kind != .app {
            await cancelPendingDesktopStreamLightsOutSetup(reason: "client cancelled desktop stream setup")
        }

        if request.kind != .app, desktopStreamID != nil {
            await stopDesktopStream(reason: .clientRequested)
        }

        if request.kind != .desktop,
           let appSessionID = request.appSessionID {
            await cancelStartingAppSession(appSessionID: appSessionID)
        }
    }

    /// Returns whether desktop startup rejected a valid request for an expected runtime reason.
    private nonisolated static func isExpectedDesktopStartRejection(_ error: Error) -> Bool {
        if error is MirageRuntimeConditionError { return true }
        if case let MirageError.protocolError(message) = error {
            if message.contains("Desktop stream already active") {
                return true
            }
            return message.contains("Virtual display acquisition failed for desktop stream:") ||
                message.contains("client disconnected during startup") ||
                message.contains("Desktop geometry contract required for AWDL desktop startup") ||
                message.contains("cancelled by client")
        }
        return false
    }

    /// Returns whether a desktop-start failure came from a malformed control message.
    private nonisolated static func isDesktopStartDecodeError(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }

        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == 3840 || nsError.code == 4864
    }

    /// Builds the protocol error payload sent when desktop startup fails before acknowledgement.
    private nonisolated static func desktopStartErrorPayload(for error: Error) -> ErrorMessage {
        if let runtimeCondition = error as? MirageRuntimeConditionError {
            return ErrorMessage(code: .init(runtimeCondition), message: runtimeCondition.message)
        }

        return ErrorMessage(
            code: isDesktopStartDecodeError(error) ? .invalidMessage : .virtualDisplayStartFailed,
            message: "Failed to start desktop stream: \(error.localizedDescription)"
        )
    }

    /// Queries the host's current main display resolution in logical points.
    private static func hostMainDisplayLogicalResolution() -> CGSize? {
        let mainDisplay = CGMainDisplayID()
        if let modeLogicalResolution = CGVirtualDisplayBridge.currentDisplayModeSizes(mainDisplay)?.logical,
           modeLogicalResolution.width > 0,
           modeLogicalResolution.height > 0 {
            return modeLogicalResolution
        }

        let bounds = CGDisplayBounds(mainDisplay)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds.size
    }
}

#endif
