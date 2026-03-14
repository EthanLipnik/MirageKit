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

        let maxPixelSize = min(max(request.preferredMaxPixelSize, 128), 1024)
        guard let payload = MirageHostHardwareIconResolver.payload(
            preferredIconName: advertisedPeerAdvertisement.iconName,
            hardwareMachineFamily: advertisedPeerAdvertisement.machineFamily,
            hardwareModelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
            maxPixelSize: maxPixelSize
        ) else {
            MirageLogger.host("Host hardware icon request failed: no icon payload")
            return
        }

        let response = HostHardwareIconMessage(
            pngData: payload.pngData,
            iconName: payload.iconName,
            hardwareModelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
            hardwareMachineFamily: advertisedPeerAdvertisement.machineFamily
        )

        do {
            try await clientContext.send(.hostHardwareIcon, content: response)
            MirageLogger.host("Sent host hardware icon payload bytes=\(payload.pngData.count) icon=\(payload.iconName)")
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Host hardware icon response"
            )
        }
    }
}
#endif
