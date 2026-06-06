//
//  MirageLocalIdentitySnapshot+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageIdentity

public extension MirageLocalIdentitySnapshot {
    /// Creates a Mirage identity snapshot from the current Loom account identity descriptor.
    init(loomIdentity identity: LoomAccountIdentity) {
        self.init(
            keyID: identity.keyID,
            publicKey: identity.publicKey
        )
    }
}
