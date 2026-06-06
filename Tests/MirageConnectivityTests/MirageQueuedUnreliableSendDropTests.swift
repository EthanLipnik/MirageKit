//
//  MirageQueuedUnreliableSendDropTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
@testable import MirageConnectivity
import Testing

@Suite("Mirage Queued Unreliable Send Drop")
struct MirageQueuedUnreliableSendDropTests {
    @Test("Queued unreliable send drops project Loom metadata")
    func queuedUnreliableSendDropsProjectLoomMetadata() throws {
        let drop = LoomQueuedUnreliableSendDrop(
            reason: .queueLimit,
            profile: .proximityRealtimeDisplay,
            frameID: 44,
            fragmentIndex: 2,
            fragmentCount: 5
        )

        let snapshot = try #require(MirageQueuedUnreliableSendDrop(error: drop))

        #expect(snapshot.reason == .queueLimit)
        #expect(snapshot.profile == .proximityRealtimeDisplay)
        #expect(snapshot.frameID == 44)
        #expect(snapshot.fragmentIndex == 2)
        #expect(snapshot.fragmentCount == 5)
        #expect(MirageQueuedUnreliableSendDrop(error: NSError(domain: "other", code: 1)) == nil)
    }
}
