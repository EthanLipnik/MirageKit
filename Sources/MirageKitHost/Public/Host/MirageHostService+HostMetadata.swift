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
}
#endif
