//
//  MirageQueuedUnreliableSendDiagnosticsTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
@testable import MirageConnectivity
import Testing

@Suite("Mirage Queued Unreliable Send Diagnostics")
struct MirageQueuedUnreliableSendDiagnosticsTests {
    @Test("Queued unreliable diagnostics project Loom counters")
    func queuedUnreliableDiagnosticsProjectLoomCounters() {
        let loomDiagnostics = LoomQueuedUnreliableSendDiagnostics(
            profile: .proximityRealtimeDisplay,
            pendingPackets: 1,
            outstandingPackets: 2,
            queuedBytes: 3,
            pendingPacketMax: 4,
            outstandingPacketMax: 5,
            queuedBytesMax: 6,
            enqueuedCount: 7,
            sentCount: 8,
            completedCount: 9,
            droppedCount: 10,
            deadlineDropCount: 11,
            queueLimitDropCount: 12,
            supersededDropCount: 13,
            errorCount: 14,
            queueDwellP50Ms: 15,
            queueDwellP95Ms: 16,
            queueDwellP99Ms: 17,
            sendGapP50Ms: 18,
            sendGapP95Ms: 19,
            sendGapP99Ms: 20,
            contentProcessedP50Ms: 21,
            contentProcessedP95Ms: 22,
            contentProcessedP99Ms: 23
        )

        let diagnostics = MirageQueuedUnreliableSendDiagnostics(loomDiagnostics: loomDiagnostics)

        #expect(diagnostics.profile == .proximityRealtimeDisplay)
        #expect(diagnostics.pendingPackets == 1)
        #expect(diagnostics.outstandingPackets == 2)
        #expect(diagnostics.queuedBytes == 3)
        #expect(diagnostics.pendingPacketMax == 4)
        #expect(diagnostics.outstandingPacketMax == 5)
        #expect(diagnostics.queuedBytesMax == 6)
        #expect(diagnostics.enqueuedCount == 7)
        #expect(diagnostics.sentCount == 8)
        #expect(diagnostics.completedCount == 9)
        #expect(diagnostics.droppedCount == 10)
        #expect(diagnostics.deadlineDropCount == 11)
        #expect(diagnostics.queueLimitDropCount == 12)
        #expect(diagnostics.supersededDropCount == 13)
        #expect(diagnostics.errorCount == 14)
        #expect(diagnostics.queueDwellP50Ms == 15)
        #expect(diagnostics.queueDwellP95Ms == 16)
        #expect(diagnostics.queueDwellP99Ms == 17)
        #expect(diagnostics.sendGapP50Ms == 18)
        #expect(diagnostics.sendGapP95Ms == 19)
        #expect(diagnostics.sendGapP99Ms == 20)
        #expect(diagnostics.contentProcessedP50Ms == 21)
        #expect(diagnostics.contentProcessedP95Ms == 22)
        #expect(diagnostics.contentProcessedP99Ms == 23)
    }
}
