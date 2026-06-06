//
//  MirageAuthenticatedPeerIdentity+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageIdentity

public extension MirageAuthenticatedPeerIdentity {
    /// Creates a Mirage authenticated peer identity from the current Loom handshake identity projection.
    init(loomPeerIdentity peer: LoomPeerIdentity) {
        self.init(
            deviceID: peer.deviceID,
            displayName: peer.name,
            deviceType: MirageConnectivityLoomAdapter.deviceType(from: peer.deviceType),
            iCloudUserID: peer.iCloudUserID,
            identityKeyID: peer.identityKeyID,
            identityPublicKey: peer.identityPublicKey,
            isIdentityAuthenticated: peer.isIdentityAuthenticated,
            endpointDescription: peer.endpoint
        )
    }
}
