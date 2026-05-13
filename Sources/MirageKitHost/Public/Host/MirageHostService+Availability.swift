//
//  MirageHostService+Availability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Host connection availability surfaced through discovery metadata.
//

import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    private static let advertisementRefreshInterval: Duration = .seconds(2)

    /// Refreshes the advertised availability reason when connection capacity changes.
    func updateAdvertisedConnectionAvailability() {
        expireStaleSingleClientReservationIfNeeded()

        let updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingAvailability(
            advertisedConnectionAvailabilityReason,
            in: advertisedPeerAdvertisement
        )
        guard updatedAdvertisement != advertisedPeerAdvertisement else { return }

        advertisedPeerAdvertisement = updatedAdvertisement
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
    }

    /// Updates whether the advertised host metadata includes reusable VPN access.
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

    /// Publishes the current host advertisement when discovery is actively advertising.
    func publishCurrentAdvertisement() async {
        guard case .advertising = state else { return }

        expireStaleSingleClientReservationIfNeeded()

        var updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingAvailability(
            advertisedConnectionAvailabilityReason,
            in: advertisedPeerAdvertisement
        )
        let localNetworkSnapshot = localNetworkMonitor.snapshot
        updatedAdvertisement = MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            localNetworkSnapshot,
            in: updatedAdvertisement
        )
        if updatedAdvertisement != advertisedPeerAdvertisement {
            advertisedPeerAdvertisement = updatedAdvertisement
        }

        await loomNode.updateAdvertisement(updatedAdvertisement)
    }

    /// Updates host maintenance availability while a software update is active.
    public func updateAdvertisedSoftwareUpdateMaintenance(_ active: Bool) async {
        guard softwareUpdateMaintenanceModeActive != active else { return }
        softwareUpdateMaintenanceModeActive = active
        await publishCurrentAdvertisement()
        onConnectionAvailabilityChanged?(allowsNewClientConnections)
    }

    /// Starts periodic advertisement refreshes so local-network and availability metadata stay current.
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

    /// Stops the periodic advertisement refresh task.
    func stopAdvertisementRefreshLoop() {
        advertisementRefreshTask?.cancel()
        advertisementRefreshTask = nil
    }
}
#endif
