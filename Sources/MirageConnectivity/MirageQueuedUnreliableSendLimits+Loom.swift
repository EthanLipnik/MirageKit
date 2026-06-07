//
//  MirageQueuedUnreliableSendLimits+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageMedia

package struct MirageQueuedUnreliableSendLimits: Sendable, Codable, Equatable {
    package let maxOutstandingPackets: Int
    package let maxOutstandingBytes: Int
    package let maxQueuedPackets: Int?

    package init(loomLimits limits: LoomQueuedUnreliableSendLimits) {
        self.maxOutstandingPackets = limits.maxOutstandingPackets
        self.maxOutstandingBytes = limits.maxOutstandingBytes
        self.maxQueuedPackets = limits.maxQueuedPackets
    }
}

package extension MirageMedia.MirageMediaSendProfile {
    var queuedUnreliableRecommendedLimits: MirageQueuedUnreliableSendLimits {
        MirageQueuedUnreliableSendLimits(
            loomLimits: MirageConnectivityLoomAdapter.loomMediaSendProfile(from: self).recommendedLimits
        )
    }
}
