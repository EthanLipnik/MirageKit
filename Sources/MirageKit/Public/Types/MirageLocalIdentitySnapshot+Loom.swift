//
//  MirageLocalIdentitySnapshot+Loom.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Loom

public extension MirageKit {
    /// Returns Mirage's current local identity snapshot from the supplied identity manager.
    @MainActor
    static func currentIdentitySnapshot(
        using identityManager: LoomIdentityManager = MirageKit.identityManager
    ) throws -> MirageLocalIdentitySnapshot {
        let identity = try identityManager.currentIdentity()
        return MirageLocalIdentitySnapshot(loomIdentity: identity)
    }

    /// Returns Mirage's current local identity snapshot when an identity manager is configured.
    @MainActor
    static func currentIdentitySnapshot(
        using identityManager: LoomIdentityManager?
    ) throws -> MirageLocalIdentitySnapshot? {
        guard let identityManager else { return nil }
        let identity = try identityManager.currentIdentity()
        return MirageLocalIdentitySnapshot(loomIdentity: identity)
    }
}
