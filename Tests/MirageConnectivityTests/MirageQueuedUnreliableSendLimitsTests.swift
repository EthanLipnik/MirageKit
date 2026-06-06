//
//  MirageQueuedUnreliableSendLimitsTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
@testable import MirageConnectivity
import MirageMedia
import Testing

@Suite("Mirage Queued Unreliable Send Limits")
struct MirageQueuedUnreliableSendLimitsTests {
    @Test("Queued unreliable send limits project Loom profile recommendations")
    func queuedUnreliableSendLimitsProjectLoomRecommendations() {
        for profile in MirageMedia.MirageMediaSendProfile.allCases {
            let loomProfile = MirageConnectivityLoomAdapter.loomMediaSendProfile(from: profile)
            let loomLimits = loomProfile.recommendedLimits
            let limits = profile.queuedUnreliableRecommendedLimits

            #expect(limits.maxOutstandingPackets == loomLimits.maxOutstandingPackets)
            #expect(limits.maxOutstandingBytes == loomLimits.maxOutstandingBytes)
            #expect(limits.maxQueuedPackets == loomLimits.maxQueuedPackets)
        }
    }
}
