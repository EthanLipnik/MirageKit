//
//  MirageHostService+AdvertisementIdentity.swift
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
import Loom

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Returns whether Lights Out should be disabled by environment override.
    nonisolated static func isLightsOutDisabledByEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        MirageEnvironmentValue.isTruthy(environment[lightsOutDisableEnvironmentKey])
    }

    /// Reads the current Mirage identity snapshot when an identity manager is configured.
    static func localIdentitySnapshot(for manager: LoomIdentityManager?) -> MirageLocalIdentitySnapshot? {
        try? MirageKit.currentIdentitySnapshot(using: manager)
    }

    /// Reads the current Mirage identity key ID when an identity manager is configured.
    static func identityKeyID(for manager: LoomIdentityManager?) -> String? {
        localIdentitySnapshot(for: manager)?.keyID
    }

    /// Publishes a refreshed discovery payload with the supplied signed identity key.
    public func updateAdvertisedIdentityKeyID(_ keyID: String?) {
        advertisedPeerAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingIdentityKeyID(
            keyID,
            in: advertisedPeerAdvertisement
        )
        Task { @MainActor [weak self] in
            await self?.publishCurrentAdvertisement()
        }
    }
}
#endif
