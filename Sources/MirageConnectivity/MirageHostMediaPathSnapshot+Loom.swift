//
//  MirageHostMediaPathSnapshot+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageMedia

package func currentHostMediaPathSnapshot(
    liveSnapshot: LoomSessionNetworkPathSnapshot?,
    bootstrapSnapshot: LoomSessionNetworkPathSnapshot?
) -> MirageNetworkPathSnapshot? {
    (liveSnapshot ?? bootstrapSnapshot).map { MirageNetworkPathClassifier.classify($0) }
}
