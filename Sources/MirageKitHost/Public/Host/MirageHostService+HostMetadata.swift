//
//  MirageHostService+HostMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Host metadata request handling.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleHostHardwareIconRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: HostHardwareIconRequestMessage
        do {
            request = try message.decode(HostHardwareIconRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host hardware icon request: ")
            return
        }

        updatePendingHostHardwareIconRequest(
            clientID: clientContext.client.id,
            preferredMaxPixelSize: request.preferredMaxPixelSize
        )
        if isInteractiveWorkloadActiveForAppListRequests() {
            MirageLogger.host("Deferring host hardware icon response while interactive workload is active")
        }
        await syncAppListRequestDeferralForInteractiveWorkload()
    }

    private func updatePendingHostHardwareIconRequest(
        clientID: UUID,
        preferredMaxPixelSize: Int
    ) {
        let clampedPreferredMaxPixelSize = min(max(preferredMaxPixelSize, 128), 1024)
        if var pending = pendingHostHardwareIconRequest,
           pending.clientID == clientID {
            pending.preferredMaxPixelSize = max(
                pending.preferredMaxPixelSize,
                clampedPreferredMaxPixelSize
            )
            pendingHostHardwareIconRequest = pending
            return
        }
        pendingHostHardwareIconRequest = PendingHostHardwareIconRequest(
            clientID: clientID,
            preferredMaxPixelSize: clampedPreferredMaxPixelSize
        )
    }

    func sendPendingHostHardwareIconRequestIfPossible() {
        guard !isInteractiveWorkloadActiveForAppListRequests() else { return }
        guard let pending = pendingHostHardwareIconRequest else { return }
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

            guard let payload = MirageHostHardwareIconResolver.payload(
                preferredIconName: advertisedPeerAdvertisement.iconName,
                hardwareMachineFamily: advertisedPeerAdvertisement.machineFamily,
                hardwareModelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
                maxPixelSize: maxPixelSize
            ) else {
                MirageLogger.host("Host hardware icon request failed: no icon payload")
                if hostHardwareIconRequestToken == token,
                   pendingHostHardwareIconRequest?.clientID == clientID {
                    pendingHostHardwareIconRequest = nil
                    hostHardwareIconRequestTask = nil
                }
                return
            }
            guard !Task.isCancelled else { return }

            let response = HostHardwareIconMessage(
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
                    operation: "Host hardware icon response"
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

    func handleHostWallpaperRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: HostWallpaperRequestMessage
        do {
            request = try message.decode(HostWallpaperRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host wallpaper request: ")
            return
        }

        updatePendingHostWallpaperRequest(
            clientID: clientContext.client.id,
            requestID: request.requestID,
            preferredMaxPixelWidth: request.preferredMaxPixelWidth,
            preferredMaxPixelHeight: request.preferredMaxPixelHeight
        )
        if isInteractiveWorkloadActiveForAppListRequests() {
            MirageLogger.host("Deferring host wallpaper response while interactive workload is active")
        }
        await syncAppListRequestDeferralForInteractiveWorkload()
    }

    private func updatePendingHostWallpaperRequest(
        clientID: UUID,
        requestID: UUID,
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) {
        let clampedWidth = min(max(preferredMaxPixelWidth, 640), 1_280)
        let clampedHeight = min(max(preferredMaxPixelHeight, 360), 720)
        if var pending = pendingHostWallpaperRequest,
           pending.clientID == clientID {
            pending.preferredMaxPixelWidth = max(pending.preferredMaxPixelWidth, clampedWidth)
            pending.preferredMaxPixelHeight = max(pending.preferredMaxPixelHeight, clampedHeight)
            pendingHostWallpaperRequest = pending
            return
        }
        pendingHostWallpaperRequest = PendingHostWallpaperRequest(
            clientID: clientID,
            requestID: requestID,
            preferredMaxPixelWidth: clampedWidth,
            preferredMaxPixelHeight: clampedHeight
        )
    }

    func sendPendingHostWallpaperRequestIfPossible() {
        guard !isInteractiveWorkloadActiveForAppListRequests() else { return }
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
                preferredMaxPixelHeight: height
            ) else {
                MirageLogger.host("Host wallpaper request failed: no wallpaper payload")
                let response = HostWallpaperMessage(
                    requestID: requestID,
                    pixelWidth: 0,
                    pixelHeight: 0,
                    bytesPerPixelEstimate: 0,
                    errorMessage: "Host wallpaper is unavailable."
                )
                try? await clientContext.send(.hostWallpaper, content: response)
                if hostWallpaperRequestToken == token,
                   pendingHostWallpaperRequest?.clientID == clientID {
                    pendingHostWallpaperRequest = nil
                    hostWallpaperRequestTask = nil
                }
                return
            }
            guard !Task.isCancelled else { return }

            let wallpaperURL = temporaryWallpaperURL(
                for: requestID,
                fileExtension: payload.fileExtension
            )
            do {
                try payload.imageData.write(to: wallpaperURL, options: .atomic)
            } catch {
                let response = HostWallpaperMessage(
                    requestID: requestID,
                    pixelWidth: payload.pixelWidth,
                    pixelHeight: payload.pixelHeight,
                    bytesPerPixelEstimate: payload.bytesPerPixelEstimate,
                    errorMessage: "Failed to prepare wallpaper transfer."
                )
                try? await clientContext.send(.hostWallpaper, content: response)
                if hostWallpaperRequestToken == token,
                   pendingHostWallpaperRequest?.clientID == clientID {
                    pendingHostWallpaperRequest = nil
                    hostWallpaperRequestTask = nil
                }
                return
            }

            let response = HostWallpaperMessage(
                requestID: requestID,
                fileName: wallpaperURL.lastPathComponent,
                pixelWidth: payload.pixelWidth,
                pixelHeight: payload.pixelHeight,
                bytesPerPixelEstimate: payload.bytesPerPixelEstimate
            )

            do {
                try await clientContext.send(.hostWallpaper, content: response)
                MirageLogger.host(
                    "Sent host wallpaper payload bytes=\(payload.imageData.count) size=\(payload.pixelWidth)x\(payload.pixelHeight)"
                )
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host wallpaper response"
                )
                return
            }
            guard !Task.isCancelled else { return }

            Task { @MainActor [weak self] in
                await self?.handleHostWallpaperTransfer(
                    clientContext.controlChannel.session,
                    requestID: requestID,
                    wallpaperURL: wallpaperURL,
                    contentType: payload.contentType,
                    expectedClient: clientContext.client
                )
            }

            if hostWallpaperRequestToken == token,
               pendingHostWallpaperRequest?.clientID == clientID {
                pendingHostWallpaperRequest = nil
                hostWallpaperRequestTask = nil
            }
        }
    }

    private func handleHostWallpaperTransfer(
        _ session: LoomAuthenticatedSession,
        requestID: UUID,
        wallpaperURL: URL,
        contentType: String,
        expectedClient: MirageConnectedClient
    ) async {
        defer {
            try? FileManager.default.removeItem(at: wallpaperURL)
        }

        do {
            try await validateExistingClientTransferSession(
                session,
                expectedClient: expectedClient
            )

            let source = try LoomFileTransferSource(url: wallpaperURL)
            let byteLength = await source.byteLength
            let engine = LoomTransferEngine(session: session)
            let outgoing = try await engine.offerTransfer(
                LoomTransferOffer(
                    logicalName: wallpaperURL.lastPathComponent,
                    byteLength: byteLength,
                    contentType: contentType,
                    metadata: [
                        "mirage.transfer-kind": "host-wallpaper",
                        "mirage.request-id": requestID.uuidString.lowercased(),
                    ]
                ),
                source: source
            )

            let terminalProgress = await terminalProgress(from: outgoing.progressEvents)
            switch terminalProgress?.state {
            case .completed:
                break
            case .cancelled, .declined:
                MirageLogger.host(
                    "Host wallpaper transfer ended before completion requestID=\(requestID.uuidString.lowercased()) " +
                        "state=\(terminalProgress?.state.rawValue ?? "unknown")"
                )
                return
            default:
                throw MirageError.protocolError("Host wallpaper Loom transfer did not complete")
            }

            MirageLogger.host(
                "Completed host wallpaper Loom transfer requestID=\(requestID.uuidString.lowercased()) bytes=\(byteLength)"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed host wallpaper Loom transfer: ")
        }
    }

    private func temporaryWallpaperURL(
        for requestID: UUID,
        fileExtension: String
    ) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "mirage-wallpaper-\(requestID.uuidString.lowercased()).\(fileExtension)"
        )
    }
}
#endif
