//
//  MirageStreamingDiagnosticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Streaming Diagnostics")
struct MirageStreamingDiagnosticsTests {
    @Test("Ring buffer overwrites oldest events and counts drops")
    func ringBufferOverwriteAccounting() {
        let buffer = MirageStreamingDiagnosticsBuffer(capacity: 2)

        buffer.recordFrameMarker(streamID: 1, frameSizeBytes: 1_000, isKeyframe: false, now: 1)
        buffer.recordFrameMarker(streamID: 1, frameSizeBytes: 2_000, isKeyframe: true, now: 2)
        buffer.recordQueueDepth(streamID: 1, queuedBytes: 3_000, now: 3)

        let snapshot = buffer.snapshot()
        #expect(snapshot.capacity == 2)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.events.count == 2)
        #expect(snapshot.events.map(\.kind) == [.frameMarker, .queueDepth])
        #expect(snapshot.events.last?.primaryValue == 3_000)
    }

    @Test("Hot-path helpers store primitive buckets and flags")
    func primitiveHotPathEvents() {
        let buffer = MirageStreamingDiagnosticsBuffer(capacity: 8)

        buffer.recordFrameArrivalGap(
            streamID: 4,
            gapMs: 16.4,
            frameSizeBytes: 65_536,
            isKeyframe: true,
            now: 10
        )
        buffer.recordDecodeGap(streamID: 4, gapMs: 12.8, now: 11)
        buffer.recordPacerSleep(streamID: 4, totalMs: 7, maxMs: 3, now: 12)

        let events = buffer.snapshot().events
        #expect(events.count == 3)
        #expect(events[0].primaryValue == 16)
        #expect(events[0].frameSizeBucket == MirageStreamingDiagnosticsBuffer.frameSizeBucket(bytes: 65_536))
        #expect(events[0].flags == 1)
        #expect(events[1].primaryValue == 13)
        #expect(events[2].primaryValue == 7)
        #expect(events[2].secondaryValue == 3)
    }
}
