//
//  MirageHostService+HostMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Host metadata request handling.
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
    /// Handles a client request for the host hardware icon payload.
    func handleHostHardwareIconRequest(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: MirageWire.HostHardwareIconRequestMessage
        do {
            request = try message.decode(MirageWire.HostHardwareIconRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host hardware icon request: ")
            return
        }

        let clampedPreferredMaxPixelSize = min(max(request.preferredMaxPixelSize, 128), 1024)
        if var pending = pendingHostHardwareIconRequest,
           pending.clientID == clientContext.client.id {
            pending.preferredMaxPixelSize = max(
                pending.preferredMaxPixelSize,
                clampedPreferredMaxPixelSize
            )
            pendingHostHardwareIconRequest = pending
        } else {
            pendingHostHardwareIconRequest = PendingHostHardwareIconRequest(
                clientID: clientContext.client.id,
                preferredMaxPixelSize: clampedPreferredMaxPixelSize
            )
        }

        sendPendingHostHardwareIconRequestIfPossible()
    }

    /// Sends a pending host hardware icon response when interactive work is idle.
    func sendPendingHostHardwareIconRequestIfPossible() {
        guard let pending = pendingHostHardwareIconRequest else { return }
        guard !isInteractiveWorkloadActiveForAppListRequests else {
            MirageLogger.host("Deferring host hardware icon response while interactive workload is active")
            return
        }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingHostHardwareIconRequest = nil
            return
        }

        hostHardwareIconRequestTask?.cancel()
        let token = UUID()
        let clientID = pending.clientID
        let maxPixelSize = pending.preferredMaxPixelSize
        hostHardwareIconRequestToken = token
        hostHardwareIconRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let preferredIconName = advertisedPeerAdvertisement.iconName
            let hardwareMachineFamily = advertisedPeerAdvertisement.machineFamily
            let hardwareModelIdentifier = advertisedPeerAdvertisement.modelIdentifier
            let payload = await Task.detached(priority: .userInitiated) {
                MirageHostHardwareIconResolver.payload(
                    preferredIconName: preferredIconName,
                    hardwareMachineFamily: hardwareMachineFamily,
                    hardwareModelIdentifier: hardwareModelIdentifier,
                    maxPixelSize: maxPixelSize
                )
            }.value

            guard let payload else {
                MirageLogger.host("Host hardware icon request failed: no icon payload")
                if hostHardwareIconRequestToken == token,
                   pendingHostHardwareIconRequest?.clientID == clientID {
                    pendingHostHardwareIconRequest = nil
                    hostHardwareIconRequestTask = nil
                }
                return
            }
            guard !Task.isCancelled else { return }

            let response = MirageWire.HostHardwareIconMessage(
                pngData: payload.pngData,
                iconName: payload.iconName,
                hardwareModelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
                hardwareMachineFamily: advertisedPeerAdvertisement.machineFamily
            )

            do {
                try await clientContext.send(.hostHardwareIcon, content: response)
                MirageLogger.host(
                    "Sent host hardware icon payload bytes=\(payload.pngData.count) icon=\(payload.iconName)"
                )
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host hardware icon response",
                    sessionID: clientContext.sessionID
                )
                return
            }
            guard !Task.isCancelled else { return }

            if hostHardwareIconRequestToken == token,
               pendingHostHardwareIconRequest?.clientID == clientID {
                pendingHostHardwareIconRequest = nil
                hostHardwareIconRequestTask = nil
            }
        }
    }

    /// Handles a client request for the host wallpaper payload.
    func handleHostWallpaperRequest(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: MirageWire.HostWallpaperRequestMessage
        do {
            request = try message.decode(MirageWire.HostWallpaperRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host wallpaper request: ")
            return
        }

        let clampedSize = MirageHostWallpaperResolver.clampedRequestedOutputSize(
            preferredMaxPixelWidth: request.preferredMaxPixelWidth,
            preferredMaxPixelHeight: request.preferredMaxPixelHeight
        )
        let clampedWidth = Int(clampedSize.width)
        let clampedHeight = Int(clampedSize.height)
        if var pending = pendingHostWallpaperRequest,
           pending.clientID == clientContext.client.id {
            pending.preferredMaxPixelWidth = max(pending.preferredMaxPixelWidth, clampedWidth)
            pending.preferredMaxPixelHeight = max(pending.preferredMaxPixelHeight, clampedHeight)
            pendingHostWallpaperRequest = pending
        } else {
            pendingHostWallpaperRequest = PendingHostWallpaperRequest(
                clientID: clientContext.client.id,
                requestID: request.requestID,
                preferredMaxPixelWidth: clampedWidth,
                preferredMaxPixelHeight: clampedHeight
            )
        }

        sendPendingHostWallpaperRequestIfPossible()
    }

    /// Sends a pending host wallpaper response to the requesting client.
    func sendPendingHostWallpaperRequestIfPossible() {
        guard let pending = pendingHostWallpaperRequest else { return }
        guard let clientContext = findClientContext(clientID: pending.clientID) else {
            pendingHostWallpaperRequest = nil
            return
        }

        hostWallpaperRequestTask?.cancel()
        let token = UUID()
        let clientID = pending.clientID
        let requestID = pending.requestID
        let width = pending.preferredMaxPixelWidth
        let height = pending.preferredMaxPixelHeight
        hostWallpaperRequestToken = token
        hostWallpaperRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            guard let payload = await MirageHostWallpaperResolver.payload(
                preferredMaxPixelWidth: width,
                preferredMaxPixelHeight: height,
                virtualDisplayBackend: platformVirtualDisplayBackend,
                captureContentProviderBackend: platformCaptureContentProviderBackend
            ) else {
                MirageLogger.host("Host wallpaper request failed: no wallpaper payload")
                let response = MirageWire.HostWallpaperMessage(
                    requestID: requestID,
                    pixelWidth: 0,
                    pixelHeight: 0,
                    errorMessage: "Host wallpaper is unavailable."
                )
                do {
                    try await clientContext.send(.hostWallpaper, content: response)
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to send hostWallpaper error response: ")
                }
                if hostWallpaperRequestToken == token,
                   pendingHostWallpaperRequest?.clientID == clientID {
                    pendingHostWallpaperRequest = nil
                    hostWallpaperRequestTask = nil
                }
                return
            }
            guard !Task.isCancelled else { return }

            let response = MirageWire.HostWallpaperMessage(
                requestID: requestID,
                imageData: payload.imageData,
                pixelWidth: payload.pixelWidth,
                pixelHeight: payload.pixelHeight
            )

            do {
                let interval = MirageLogger.beginInterval(.host, "HostWallpaper.Send")
                defer {
                    MirageLogger.endInterval(interval)
                }
                try await clientContext.send(.hostWallpaper, content: response)
                MirageLogger.host(
                    "Sent host wallpaper payload bytes=\(payload.imageData.count) size=\(payload.pixelWidth)x\(payload.pixelHeight)"
                )
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host wallpaper response",
                    sessionID: clientContext.sessionID
                )
                return
            }

            if hostWallpaperRequestToken == token,
               pendingHostWallpaperRequest?.clientID == clientID {
                pendingHostWallpaperRequest = nil
                hostWallpaperRequestTask = nil
            }
        }
    }
}
#endif
