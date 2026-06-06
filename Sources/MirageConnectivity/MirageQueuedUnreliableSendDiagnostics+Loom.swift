//
//  MirageQueuedUnreliableSendDiagnostics+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageMedia

package struct MirageQueuedUnreliableSendDiagnostics: Sendable, Codable, Equatable {
    package let profile: MirageMedia.MirageMediaSendProfile?
    package let pendingPackets: Int
    package let outstandingPackets: Int
    package let queuedBytes: Int
    package let pendingPacketMax: Int
    package let outstandingPacketMax: Int
    package let queuedBytesMax: Int
    package let enqueuedCount: UInt64
    package let sentCount: UInt64
    package let completedCount: UInt64
    package let droppedCount: UInt64
    package let deadlineDropCount: UInt64
    package let queueLimitDropCount: UInt64
    package let supersededDropCount: UInt64
    package let errorCount: UInt64
    package let queueDwellP50Ms: Double
    package let queueDwellP95Ms: Double
    package let queueDwellP99Ms: Double
    package let sendGapP50Ms: Double
    package let sendGapP95Ms: Double
    package let sendGapP99Ms: Double
    package let contentProcessedP50Ms: Double
    package let contentProcessedP95Ms: Double
    package let contentProcessedP99Ms: Double

    package init(loomDiagnostics diagnostics: LoomQueuedUnreliableSendDiagnostics) {
        self.profile = diagnostics.profile.map(MirageMedia.MirageMediaSendProfile.init(loomProfile:))
        self.pendingPackets = diagnostics.pendingPackets
        self.outstandingPackets = diagnostics.outstandingPackets
        self.queuedBytes = diagnostics.queuedBytes
        self.pendingPacketMax = diagnostics.pendingPacketMax
        self.outstandingPacketMax = diagnostics.outstandingPacketMax
        self.queuedBytesMax = diagnostics.queuedBytesMax
        self.enqueuedCount = diagnostics.enqueuedCount
        self.sentCount = diagnostics.sentCount
        self.completedCount = diagnostics.completedCount
        self.droppedCount = diagnostics.droppedCount
        self.deadlineDropCount = diagnostics.deadlineDropCount
        self.queueLimitDropCount = diagnostics.queueLimitDropCount
        self.supersededDropCount = diagnostics.supersededDropCount
        self.errorCount = diagnostics.errorCount
        self.queueDwellP50Ms = diagnostics.queueDwellP50Ms
        self.queueDwellP95Ms = diagnostics.queueDwellP95Ms
        self.queueDwellP99Ms = diagnostics.queueDwellP99Ms
        self.sendGapP50Ms = diagnostics.sendGapP50Ms
        self.sendGapP95Ms = diagnostics.sendGapP95Ms
        self.sendGapP99Ms = diagnostics.sendGapP99Ms
        self.contentProcessedP50Ms = diagnostics.contentProcessedP50Ms
        self.contentProcessedP95Ms = diagnostics.contentProcessedP95Ms
        self.contentProcessedP99Ms = diagnostics.contentProcessedP99Ms
    }
}

extension LoomMultiplexedStream {
    package func mirageQueuedUnreliableSendDiagnostics(
        profile: MirageMedia.MirageMediaSendProfile
    ) async -> MirageQueuedUnreliableSendDiagnostics? {
        await consumeQueuedUnreliableSendDiagnostics(
            profile: MirageConnectivityLoomAdapter.loomMediaSendProfile(from: profile)
        ).map(MirageQueuedUnreliableSendDiagnostics.init(loomDiagnostics:))
    }
}
