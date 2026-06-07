//
//  MirageHostService+StreamControlMessages.swift
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
    /// Applies a client-requested display-size change to an active stream.
    func handleDisplayResolutionChangeMessage(_ message: MirageWire.ControlMessage) async {
        do {
            let request = try message.decode(MirageWire.DisplayResolutionChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested display size change for stream \(request.streamID): " +
                        "\(request.displayWidth)x\(request.displayHeight) pts"
                )
            let baseResolution = CGSize(width: request.displayWidth, height: request.displayHeight)
            await handleDisplayResolutionChange(
                streamID: request.streamID,
                newResolution: baseResolution,
                    transitionID: request.transitionID,
                    requestedDisplayScaleFactor: request.requestedDisplayScaleFactor,
                    requestedStreamScale: request.requestedStreamScale,
                    encoderMaxWidth: request.encoderMaxWidth,
                    encoderMaxHeight: request.encoderMaxHeight,
                    desktopGeometryContractID: request.desktopGeometryContractID,
                    desktopGeometrySceneIdentity: request.desktopGeometrySceneIdentity,
                    desktopGeometryRefreshTargetHz: request.desktopGeometryRefreshTargetHz
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle displayResolutionChange: ")
        }
    }

    /// Applies a client-requested stream scale change to an active stream.
    func handleStreamScaleChangeMessage(_ message: MirageWire.ControlMessage) async {
        do {
            let request = try message.decode(MirageWire.StreamScaleChangeMessage.self)
            MirageLogger
                .host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
            await handleStreamScaleChange(streamID: request.streamID, streamScale: request.streamScale)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamScaleChange: ")
        }
    }

    /// Applies a client-requested refresh-rate override to an active stream.
    func handleStreamRefreshRateChangeMessage(_ message: MirageWire.ControlMessage) async {
        do {
            let request = try message.decode(MirageWire.StreamRefreshRateChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested refresh rate override for stream \(request.streamID): \(request.maxRefreshRate)Hz"
            )
            let adaptiveFloorFPS = request.maxRefreshRate >= 90 ? 60 : request.maxRefreshRate
            let latencyMode = if let context = streamsByID[request.streamID] {
                context.latencyMode
            } else {
                MirageMedia.MirageStreamLatencyMode.lowestLatency
            }
            MirageLogger.host(
                "event=cadence_contract phase=host_refresh_request stream=\(request.streamID) " +
                    "requested=\(request.maxRefreshRate) source=\(request.maxRefreshRate) " +
                    "display=\(request.maxRefreshRate) adaptiveFloor=\(adaptiveFloorFPS) " +
                    "latency=\(latencyMode.rawValue) force=\(request.forceDisplayRefresh)"
            )
            await handleStreamRefreshRateChange(
                streamID: request.streamID,
                maxRefreshRate: request.maxRefreshRate,
                forceDisplayRefresh: request.forceDisplayRefresh
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamRefreshRateChange: ")
        }
    }

    /// Applies partial encoder-setting updates sent by the client for an active stream.
    func handleStreamEncoderSettingsChangeMessage(_ message: MirageWire.ControlMessage, from clientContext: ClientContext) async {
        do {
            let request = try message.decode(MirageWire.StreamEncoderSettingsChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested encoder settings change for stream \(request.streamID): " +
                        "colorDepth=\(request.colorDepth?.displayName ?? "unchanged"), " +
                        "bitrate=\(request.bitrate.map(String.init) ?? "unchanged"), " +
                        "scale=\(request.streamScale.map(String.init(describing:)) ?? "unchanged"), " +
                        "fps=\(request.targetFrameRate.map(String.init) ?? "unchanged")"
                )
            await handleStreamEncoderSettingsChange(request, from: clientContext)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamEncoderSettingsChange: ")
        }
    }

    /// Updates desktop cursor presentation preferences for an active stream.
    func handleDesktopCursorPresentationChangeMessage(_ message: MirageWire.ControlMessage) async {
        do {
            let request = try message.decode(MirageWire.DesktopCursorPresentationChangeMessage.self)
            MirageLogger.host(
                "Client requested desktop cursor presentation change for stream \(request.streamID): " +
                    "source=\(request.cursorPresentation.source.rawValue), " +
                    "lockClientCursor=\(request.cursorPresentation.lockClientCursorWhenUsingHostCursor)"
            )
            await handleDesktopCursorPresentationChange(request)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle desktopCursorPresentationChange: ")
        }
    }
}
#endif
