//
//  MirageHostService+AdvertisementIdentity.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Returns whether Lights Out should be disabled by environment override.
    nonisolated static func isLightsOutDisabledByEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        MirageEnvironmentValue.isTruthy(environment[lightsOutDisableEnvironmentKey])
    }

    /// Reads the current Loom identity key ID when an identity manager is configured.
    static func identityKeyID(for manager: LoomIdentityManager?) -> String? {
        guard let manager else { return nil }
        return try? manager.currentIdentity().keyID
    }

    /// Publishes a refreshed discovery payload with the supplied signed identity key.
    public func updateAdvertisedIdentityKeyID(_ keyID: String?) {
        advertisedPeerAdvertisement = LoomPeerAdvertisement(
            protocolVersion: advertisedPeerAdvertisement.protocolVersion,
            deviceID: advertisedPeerAdvertisement.deviceID,
            identityKeyID: keyID,
            deviceType: advertisedPeerAdvertisement.deviceType,
            modelIdentifier: advertisedPeerAdvertisement.modelIdentifier,
            iconName: advertisedPeerAdvertisement.iconName,
            machineFamily: advertisedPeerAdvertisement.machineFamily,
            hostName: advertisedPeerAdvertisement.hostName,
            directTransports: advertisedPeerAdvertisement.directTransports,
            metadata: advertisedPeerAdvertisement.metadata
        )
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
    }
}
#endif
