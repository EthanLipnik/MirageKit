//
//  MirageQueuedUnreliableSendDrop+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageMedia

package enum MirageQueuedUnreliableSendDropReason: String, Sendable, Codable, Equatable {
    case deadlineExpired
    case queueLimit
    case superseded
    case unsupportedTransport
    case closed
}

package struct MirageQueuedUnreliableSendDrop: Sendable, Codable, Equatable {
    package let reason: MirageQueuedUnreliableSendDropReason
    package let profile: MirageMedia.MirageMediaSendProfile?
    package let frameID: UInt64?
    package let fragmentIndex: Int?
    package let fragmentCount: Int?

    package init(
        reason: MirageQueuedUnreliableSendDropReason,
        profile: MirageMedia.MirageMediaSendProfile? = nil,
        frameID: UInt64? = nil,
        fragmentIndex: Int? = nil,
        fragmentCount: Int? = nil
    ) {
        self.reason = reason
        self.profile = profile
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }

    package init?(error: Error?) {
        guard let drop = error as? LoomQueuedUnreliableSendDrop else { return nil }
        self.init(
            reason: MirageQueuedUnreliableSendDropReason(loomReason: drop.reason),
            profile: drop.profile.map(MirageMedia.MirageMediaSendProfile.init(loomProfile:)),
            frameID: drop.frameID,
            fragmentIndex: drop.fragmentIndex,
            fragmentCount: drop.fragmentCount
        )
    }
}

private extension MirageQueuedUnreliableSendDropReason {
    init(loomReason reason: LoomQueuedUnreliableSendDrop.Reason) {
        switch reason {
        case .deadlineExpired:
            self = .deadlineExpired
        case .queueLimit:
            self = .queueLimit
        case .superseded:
            self = .superseded
        case .unsupportedTransport:
            self = .unsupportedTransport
        case .closed:
            self = .closed
        }
    }
}
