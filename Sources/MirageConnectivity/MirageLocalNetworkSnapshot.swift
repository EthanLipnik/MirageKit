//
//  MirageLocalNetworkSnapshot.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageCore

package struct MirageLocalNetworkSnapshot: Sendable, Equatable {
    package let currentPathKind: MirageCore.MirageNetworkPathKind
    package let wifiSubnetSignatures: [String]
    package let wiredSubnetSignatures: [String]

    package init(
        currentPathKind: MirageCore.MirageNetworkPathKind,
        wifiSubnetSignatures: [String],
        wiredSubnetSignatures: [String]
    ) {
        self.currentPathKind = currentPathKind
        self.wifiSubnetSignatures = wifiSubnetSignatures
        self.wiredSubnetSignatures = wiredSubnetSignatures
    }

    /// Combines Wi-Fi and wired subnet fingerprints into the set used for local-network overlap checks.
    package static func subnetSignatureSet(
        wifiSubnetSignatures: [String],
        wiredSubnetSignatures: [String]
    ) -> Set<String> {
        Set(wifiSubnetSignatures).union(wiredSubnetSignatures)
    }
}
