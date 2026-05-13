//
//  MirageHostService+StreamControlMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Applies a client-requested display-size change to an active stream.
    func handleDisplayResolutionChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(DisplayResolutionChangeMessage.self)
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
                encoderMaxHeight: request.encoderMaxHeight
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle displayResolutionChange: ")
        }
    }

    /// Applies a client-requested stream scale change to an active stream.
    func handleStreamScaleChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamScaleChangeMessage.self)
            MirageLogger
                .host("Client requested stream scale change for stream \(request.streamID): \(request.streamScale)")
            await handleStreamScaleChange(streamID: request.streamID, streamScale: request.streamScale)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamScaleChange: ")
        }
    }

    /// Applies a client-requested refresh-rate override to an active stream.
    func handleStreamRefreshRateChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamRefreshRateChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested refresh rate override for stream \(request.streamID): \(request.maxRefreshRate)Hz"
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
    func handleStreamEncoderSettingsChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(StreamEncoderSettingsChangeMessage.self)
            MirageLogger
                .host(
                    "Client requested encoder settings change for stream \(request.streamID): " +
                        "colorDepth=\(request.colorDepth?.displayName ?? "unchanged"), " +
                        "bitrate=\(request.bitrate.map(String.init) ?? "unchanged"), " +
                        "scale=\(request.streamScale.map(String.init(describing:)) ?? "unchanged"), " +
                        "fps=\(request.targetFrameRate.map(String.init) ?? "unchanged")"
                )
            await handleStreamEncoderSettingsChange(request)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle streamEncoderSettingsChange: ")
        }
    }

    /// Updates desktop cursor presentation preferences for an active stream.
    func handleDesktopCursorPresentationChangeMessage(_ message: ControlMessage) async {
        do {
            let request = try message.decode(DesktopCursorPresentationChangeMessage.self)
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
