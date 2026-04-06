//
//  MirageHostService+Availability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Host connection availability surfaced through discovery metadata.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    private static let advertisementRefreshInterval: Duration = .seconds(2)

    func updateAdvertisedConnectionAvailability() {
        expireStaleSingleClientReservationIfNeeded()

        let updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingAcceptingConnections(
            allowsNewClientConnections,
            in: advertisedPeerAdvertisement
        )
        guard updatedAdvertisement != advertisedPeerAdvertisement else { return }

        advertisedPeerAdvertisement = updatedAdvertisement
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
    }

    public func updateAdvertisedVPNAccessEnabled(_ enabled: Bool) {
        let updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingVPNAccessEnabled(
            enabled,
            in: advertisedPeerAdvertisement
        )
        guard updatedAdvertisement != advertisedPeerAdvertisement else { return }

        advertisedPeerAdvertisement = updatedAdvertisement
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
    }

    func publishCurrentAdvertisement() async {
        guard case .advertising = state else { return }

        expireStaleSingleClientReservationIfNeeded()

        var updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingAcceptingConnections(
            allowsNewClientConnections,
            in: advertisedPeerAdvertisement
        )
        let localNetworkSnapshot = localNetworkMonitor.snapshot()
        updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            localNetworkSnapshot,
            in: updatedAdvertisement
        )
        if updatedAdvertisement != advertisedPeerAdvertisement {
            advertisedPeerAdvertisement = updatedAdvertisement
        }

        await loomNode.updateAdvertisement(updatedAdvertisement)
    }

    func startAdvertisementRefreshLoop() {
        stopAdvertisementRefreshLoop()
        advertisementRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.advertisementRefreshInterval)
                } catch {
                    return
                }
                await publishCurrentAdvertisement()
            }
        }
    }

    func stopAdvertisementRefreshLoop() {
        advertisementRefreshTask?.cancel()
        advertisementRefreshTask = nil
    }
}
#endif
