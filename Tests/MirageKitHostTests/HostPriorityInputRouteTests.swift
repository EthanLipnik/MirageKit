//
//  HostPriorityInputRouteTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/16/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

@Suite("Host Priority Input Route")
struct HostPriorityInputRouteTests {
    @Test("Realtime fallback duplicates and stale movement are dropped")
    func realtimeFallbackDuplicatesAndStaleMovementAreDropped() async throws {
        let streamID: StreamID = 801
        let queue = DispatchQueue(label: "com.mirage.tests.host-priority-input-realtime")
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordHostPriorityInputEvent(from: message, into: events)
        }
        let route = HostPriorityInputRoute(inputScheduler: scheduler)

        route.handleControlInputMessage(try priorityInputMessage(
            eventID: 1,
            streamID: streamID,
            event: .mouseMoved(makeHostPriorityMouseEvent(timestamp: 2))
        ))
        route.handleControlInputMessage(try priorityInputMessage(
            eventID: 1,
            streamID: streamID,
            event: .mouseMoved(makeHostPriorityMouseEvent(timestamp: 2))
        ))
        route.handleControlInputMessage(try priorityInputMessage(
            eventID: 2,
            streamID: streamID,
            event: .mouseMoved(makeHostPriorityMouseEvent(timestamp: 1))
        ))

        try await waitForHostPriorityEvents(events, count: 1)

        #expect(events.read { $0.map(\.timestamp) } == [2])
        #expect(route.snapshot().controlFallbackReceiveCount == 3)
        #expect(route.snapshot().dedupeCount == 2)
    }

    @Test("Continuous fallback envelope decodes and schedules ordered samples")
    func continuousFallbackEnvelopeDecodesAndSchedulesOrderedSamples() async throws {
        let streamID: StreamID = 802
        let queue = DispatchQueue(label: "com.mirage.tests.host-priority-input-continuous")
        let events = Locked<[MirageInputEvent]>([])
        let activeStreamIDs = Locked<[StreamID]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordHostPriorityInputEvent(from: message, into: events)
        }
        let route = HostPriorityInputRoute(inputScheduler: scheduler) { streamID in
            activeStreamIDs.withLock { $0.append(streamID) }
        }

        route.handleControlInputMessage(try priorityContinuousInputMessage(
            eventID: 10,
            batch: MirageContinuousInputBatch(
                streamID: streamID,
                kind: .mouseMoved,
                samples: [
                    MirageContinuousInputBatch.Sample(
                        timestamp: 1,
                        location: CGPoint(x: 0.1, y: 0.5)
                    ),
                    MirageContinuousInputBatch.Sample(
                        timestamp: 2,
                        location: CGPoint(x: 0.2, y: 0.5)
                    ),
                ]
            )
        ))

        #expect(activeStreamIDs.read { $0 } == [streamID])
        try await waitForHostPriorityEvents(events, count: 2)

        #expect(events.read { $0.map(\.timestamp) } == [1, 2])
        #expect(route.snapshot().controlFallbackReceiveCount == 1)
        #expect(route.snapshot().continuousReceiveCount == 1)
    }
}

private func priorityInputMessage(
    eventID: UInt64,
    streamID: StreamID,
    event: MirageInputEvent
) throws -> ControlMessage {
    let inputMessage = InputEventMessage(streamID: streamID, event: event)
    let envelope = MiragePriorityInputEnvelope(
        kind: .input,
        eventID: eventID,
        streamID: streamID,
        deliveryClass: .realtime,
        sentAtUptime: ProcessInfo.processInfo.systemUptime,
        inputPayload: try inputMessage.serializePayload()
    )
    return ControlMessage(type: .priorityInputEvent, payload: try envelope.serialize())
}

private func priorityContinuousInputMessage(
    eventID: UInt64,
    batch: MirageContinuousInputBatch
) throws -> ControlMessage {
    let envelope = MiragePriorityInputEnvelope(
        kind: .continuousInput,
        eventID: eventID,
        streamID: batch.streamID,
        deliveryClass: .realtime,
        sentAtUptime: ProcessInfo.processInfo.systemUptime,
        inputPayload: try batch.serialize()
    )
    return ControlMessage(type: .priorityInputEvent, payload: try envelope.serialize())
}

private func recordHostPriorityInputEvent(
    from message: ControlMessage,
    into events: Locked<[MirageInputEvent]>
) {
    guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else { return }
    events.withLock { $0.append(inputMessage.event) }
}

private func waitForHostPriorityEvents(
    _ events: Locked<[MirageInputEvent]>,
    count: Int
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while events.read({ $0.count }) < count, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events.read { $0.count } >= count)
}

private func makeHostPriorityMouseEvent(timestamp: TimeInterval) -> MirageMouseEvent {
    MirageMouseEvent(
        location: CGPoint(x: 0.5, y: 0.5),
        timestamp: timestamp
    )
}
#endif
