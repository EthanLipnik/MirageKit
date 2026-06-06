//
//  MirageHostService+Availability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Host connection availability surfaced through discovery metadata.
//


import Loom
import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
@MainActor
extension MirageHostService {
    private static let advertisementRefreshInterval: Duration = .seconds(2)

    /// Refreshes the advertised availability reason when connection capacity changes.
    func updateAdvertisedConnectionAvailability() {
        expireStaleSingleClientReservationIfNeeded()

        let updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingAvailability(
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
        let updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingVPNAccessEnabled(
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

        var updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingAvailability(
            advertisedConnectionAvailabilityReason,
            in: advertisedPeerAdvertisement
        )
        let localNetworkSnapshot = localNetworkMonitor.snapshot
        updatedAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            localNetworkSnapshot,
            in: updatedAdvertisement
        )
        if updatedAdvertisement != advertisedPeerAdvertisement {
            advertisedPeerAdvertisement = updatedAdvertisement
        }

        await loomNode.updateAdvertisement(updatedAdvertisement)
        notifyCloudKitLocalEndpointHintChangedIfNeeded()
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

    /// Builds the host advertisement used for CloudKit registration, including bounded CloudKit-only local hints.
    @_spi(HostApp) public func currentCloudKitPeerAdvertisement() -> LoomPeerAdvertisement {
        expireStaleSingleClientReservationIfNeeded()

        var advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingAvailability(
            advertisedConnectionAvailabilityReason,
            in: advertisedPeerAdvertisement
        )
        let localNetworkSnapshot = localNetworkMonitor.snapshot
        advertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            localNetworkSnapshot,
            in: advertisement
        )
        return MirageConnectivity.MiragePeerAdvertisementMetadata.updatingLocalEndpointHints(
            localEndpointHosts: localNetworkMonitor.localEndpointHosts,
            localNetwork: localNetworkSnapshot,
            in: advertisement
        )
    }

    private func notifyCloudKitLocalEndpointHintChangedIfNeeded() {
        let fingerprint = Self.cloudKitLocalEndpointHintFingerprint(currentCloudKitPeerAdvertisement())
        guard fingerprint != lastCloudKitLocalEndpointHintFingerprint else { return }
        lastCloudKitLocalEndpointHintFingerprint = fingerprint
        guard fingerprint != nil else { return }
        onCloudKitLocalEndpointHintChanged?()
    }

    private static func cloudKitLocalEndpointHintFingerprint(
        _ advertisement: LoomPeerAdvertisement
    ) -> String? {
        guard let hint = advertisement.mirageLocalNetworkEndpointHints.first else {
            return nil
        }
        return [
            hint.network.wifiSubnetSignatures.joined(separator: ","),
            hint.network.wiredSubnetSignatures.joined(separator: ","),
            hint.hosts.joined(separator: ","),
        ].joined(separator: "|")
    }

    static func advertisement(
        _ advertisement: LoomPeerAdvertisement,
        withDirectTransportPorts ports: [LoomTransportKind: UInt16]
    ) -> LoomPeerAdvertisement {
        let pathKindsByTransport = advertisement.directTransports.reduce(
            into: [LoomTransportKind: LoomDirectPathKind]()
        ) { result, transport in
            if let pathKind = transport.pathKind {
                result[transport.transportKind] = pathKind
            }
        }
        let directTransports = LoomTransportKind.allCases.compactMap {
            transportKind -> LoomDirectTransportAdvertisement? in
            guard let port = ports[transportKind], port > 0 else {
                return nil
            }
            return LoomDirectTransportAdvertisement(
                transportKind: transportKind,
                port: port,
                pathKind: pathKindsByTransport[transportKind]
            )
        }

        return LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: directTransports,
            metadata: advertisement.metadata
        )
    }
}
#endif
