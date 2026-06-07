//
//  MirageClientService+HostAssetMessages.swift
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

@MainActor
extension MirageClientService {
    /// Delivers host hardware icon metadata for the currently connected host.
    func handleHostHardwareIcon(_ message: MirageWire.ControlMessage) {
        do {
            let hostIcon = try message.decode(MirageWire.HostHardwareIconMessage.self)
            guard let hostID = connectedHost?.deviceID else {
                MirageLogger.client("Ignoring host hardware icon payload without a connected host ID")
                return
            }

            onHostHardwareIconReceived?(
                hostID,
                hostIcon.pngData,
                hostIcon.iconName,
                hostIcon.hardwareModelIdentifier,
                hostIcon.hardwareMachineFamily
            )
            MirageLogger.client(
                "Received host hardware icon payload bytes=\(hostIcon.pngData.count) icon=\(hostIcon.iconName ?? "nil") family=\(hostIcon.hardwareMachineFamily ?? "nil")"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host hardware icon: ")
        }
    }

    /// Completes a pending host wallpaper request with either image data or a protocol error.
    func handleHostWallpaper(_ message: MirageWire.ControlMessage) {
        let interval = MirageLogger.beginInterval(.client, "HostWallpaper.Receive")
        defer {
            MirageLogger.endInterval(interval)
        }

        do {
            let wallpaper = try message.decode(MirageWire.HostWallpaperMessage.self)
            guard let requestID = wallpaper.requestID,
                  requestID == hostWallpaperRequestID else {
                MirageLogger.client("Ignoring stale host wallpaper response")
                return
            }

            if let errorMessage = wallpaper.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MirageLogger.client("Host wallpaper request failed: \(errorMessage)")
                completeHostWallpaperRequest(
                    .failure(MirageCore.MirageError.protocolError(errorMessage))
                )
                return
            }

            guard let imageData = wallpaper.imageData,
                  !imageData.isEmpty,
                  let hostID = connectedHost?.deviceID else {
                MirageLogger.client("Ignoring incomplete host wallpaper payload")
                completeHostWallpaperRequest(
                    .failure(MirageCore.MirageError.protocolError("Host wallpaper payload was empty"))
                )
                return
            }

            onHostWallpaperReceived?(
                hostID,
                imageData
            )
            MirageLogger.client(
                "Received host wallpaper payload requestID=\(requestID.uuidString.lowercased()) bytes=\(imageData.count) size=\(wallpaper.pixelWidth)x\(wallpaper.pixelHeight)"
            )
            completeHostWallpaperRequest(.success(()))
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host wallpaper: ")
            completeHostWallpaperRequest(.failure(error))
        }
    }
}
