//
//  MirageConnectionErrors+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageCore

/// Creates Loom-backed Mirage connection errors inside the connectivity boundary.
package enum MirageConnectionErrors {
    package static func authenticatedSessionClosedBeforeControlStreamOpened() -> MirageCore.MirageError {
        MirageCore.MirageError.connectionFailed(
            LoomConnectionFailure(
                reason: .closed,
                detail: "Authenticated Loom session closed before Mirage control stream opened"
            )
        )
    }
}
