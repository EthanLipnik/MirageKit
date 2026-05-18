//
//  HostInputMessageSchedulerScrollTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

@Suite("Host Input Message Scheduler Scroll Coalescing")
struct HostInputMessageSchedulerScrollTests {
    @Test("Native continuous scroll messages merge by summing deltas")
    func nativeContinuousScrollMessagesMergeBySummingDeltas() async throws {
        let streamID: StreamID = 701
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-scroll-native", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }
        let location = CGPoint(x: 0.5, y: 0.5)

        scheduler.enqueue(try inputMessage(.keyDown(MirageKeyEvent(keyCode: 0x7E)), streamID: streamID))
        scheduler.enqueue(try inputMessage(.scrollWheel(MirageScrollEvent(
            deltaX: 1,
            deltaY: 2,
            location: location,
            phase: .changed,
            isPrecise: true,
            timestamp: 1
        )), streamID: streamID))
        scheduler.enqueue(try inputMessage(.scrollWheel(MirageScrollEvent(
            deltaX: 3,
            deltaY: 4,
            location: location,
            phase: .changed,
            isPrecise: true,
            timestamp: 2
        )), streamID: streamID))

        queue.activate()
        try await waitForEvents(events, count: 2)

        let scrollEvents = deliveredScrollEvents(in: events)
        #expect(scrollEvents.count == 1)
        #expect(scrollEvents.first?.deltaX == 4)
        #expect(scrollEvents.first?.deltaY == 6)
        #expect(scrollEvents.first?.phase == .changed)
        #expect(scrollEvents.first?.timestamp == 2)
    }

    @Test("Phase-less scroll messages keep replacement behavior instead of merging")
    func phaseLessScrollMessagesKeepReplacementBehaviorInsteadOfMerging() async throws {
        let streamID: StreamID = 702
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-scroll-phase-less", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }
        let location = CGPoint(x: 0.5, y: 0.5)

        scheduler.enqueue(try inputMessage(.keyDown(MirageKeyEvent(keyCode: 0x7E)), streamID: streamID))
        scheduler.enqueue(try inputMessage(.scrollWheel(MirageScrollEvent(
            deltaX: 1,
            deltaY: 2,
            location: location,
            isPrecise: true,
            timestamp: 1
        )), streamID: streamID))
        scheduler.enqueue(try inputMessage(.scrollWheel(MirageScrollEvent(
            deltaX: 3,
            deltaY: 4,
            location: location,
            isPrecise: true,
            timestamp: 2
        )), streamID: streamID))

        queue.activate()
        try await waitForEvents(events, count: 2)

        let scrollEvents = deliveredScrollEvents(in: events)
        #expect(scrollEvents.count == 1)
        #expect(scrollEvents.first?.deltaX == 3)
        #expect(scrollEvents.first?.deltaY == 4)
        #expect(scrollEvents.first?.phase == MirageScrollPhase.none)
        #expect(scrollEvents.first?.timestamp == 2)
    }

    @Test("Discrete keyboard messages survive pending continuous input trimming")
    func discreteKeyboardMessagesSurvivePendingContinuousInputTrimming() async throws {
        let streamID: StreamID = 703
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-keyboard-protected", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }
        let keyCode: UInt16 = 0x31

        for index in 0 ..< 320 {
            let event = makeMouseEvent(timestamp: TimeInterval(index))
            scheduler.enqueue(try inputMessage(index.isMultiple(of: 2) ? .mouseMoved(event) : .mouseDragged(event), streamID: streamID))
        }
        scheduler.enqueue(try inputMessage(.keyDown(MirageKeyEvent(keyCode: keyCode)), streamID: streamID))
        for index in 320 ..< 640 {
            let event = makeMouseEvent(timestamp: TimeInterval(index))
            scheduler.enqueue(try inputMessage(index.isMultiple(of: 2) ? .mouseMoved(event) : .mouseDragged(event), streamID: streamID))
        }

        queue.activate()
        try await waitForKeyboardEvent(events, keyCode: keyCode)

        let deliveredKeyboardEvents = events.read { events in
            events.compactMap { event -> MirageKeyEvent? in
                guard case let .keyDown(keyEvent) = event else { return nil }
                return keyEvent
            }
        }
        #expect(deliveredKeyboardEvents.contains { $0.keyCode == keyCode })
    }

    @Test("Queued mouse movement samples coalesce to latest pending sample")
    func queuedMouseMovementSamplesCoalesceToLatestPendingSample() async throws {
        let streamID: StreamID = 704
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-mouse-latest", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }

        for timestamp in 0 ..< 5 {
            scheduler.enqueue(try inputMessage(
                .mouseMoved(makeMouseEvent(timestamp: TimeInterval(timestamp))),
                streamID: streamID
            ))
        }

        queue.activate()
        try await waitForEvents(events, count: 1)

        #expect(events.read { $0.map(\.timestamp) } == [4])
    }

    @Test("Pointer boundary drops delayed stale movement")
    func pointerBoundaryDropsDelayedStaleMovement() async throws {
        let streamID: StreamID = 705
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-pointer-boundary", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }

        scheduler.enqueue(try inputMessage(.mouseUp(makeMouseEvent(timestamp: 10)), streamID: streamID))
        scheduler.enqueue(try inputMessage(.mouseDragged(makeMouseEvent(timestamp: 9)), streamID: streamID))

        queue.activate()
        try await waitForEvents(events, count: 1)
        try await Task.sleep(for: .milliseconds(50))

        #expect(events.read { $0.count } == 1)
        #expect(events.read { events in
            guard case .mouseUp? = events.first else { return false }
            return events.first?.timestamp == 10
        })
    }

    @Test("Pointer boundary at enqueue drops older pending movement")
    func pointerBoundaryAtEnqueueDropsOlderPendingMovement() async throws {
        let streamID: StreamID = 706
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-pointer-enqueue-boundary", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }

        scheduler.enqueue(try inputMessage(.mouseDragged(makeMouseEvent(timestamp: 9)), streamID: streamID))
        scheduler.enqueue(try inputMessage(.mouseUp(makeMouseEvent(timestamp: 10)), streamID: streamID))

        queue.activate()
        try await waitForEvents(events, count: 1)
        try await Task.sleep(for: .milliseconds(50))

        #expect(events.read { $0.count } == 1)
        #expect(events.read { events in
            guard case .mouseUp? = events.first else { return false }
            return events.first?.timestamp == 10
        })
    }

    @Test("Continuous scroll batch preserves packet samples without native merging")
    func continuousScrollBatchPreservesPacketSamplesWithoutNativeMerging() async throws {
        let streamID: StreamID = 707
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-continuous-scroll", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }
        let batch = MirageContinuousInputBatch(
            streamID: streamID,
            kind: .scroll,
            scrollPhase: .changed,
            isPrecise: true,
            samples: [
                MirageContinuousInputBatch.Sample(
                    timestamp: 1,
                    location: CGPoint(x: 0.5, y: 0.5),
                    valueX: 1,
                    valueY: 2
                ),
                MirageContinuousInputBatch.Sample(
                    timestamp: 2,
                    location: CGPoint(x: 0.5, y: 0.5),
                    valueX: 3,
                    valueY: 4
                ),
            ]
        )

        scheduler.enqueueContinuousBatch(batch)

        queue.activate()
        try await waitForEvents(events, count: 2)

        let scrollEvents = deliveredScrollEvents(in: events)
        #expect(scrollEvents.count == 2)
        #expect(scrollEvents.map(\.deltaX) == [1, 3])
        #expect(scrollEvents.map(\.deltaY) == [2, 4])
    }

    @Test("Continuous Pencil contact batches are not trimmed under backlog pressure")
    func continuousPencilContactBatchesAreNotTrimmedUnderBacklogPressure() async throws {
        let streamID: StreamID = 708
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-continuous-pencil", attributes: .initiallyInactive)
        let events = Locked<[MirageInputEvent]>([])
        let scheduler = HostInputMessageScheduler(inputQueue: queue) { message in
            recordInputEvent(from: message, into: events)
        }

        for index in 0 ..< 320 {
            scheduler.enqueueContinuousBatch(MirageContinuousInputBatch(
                streamID: streamID,
                kind: .pointerSampleBatch,
                pointerPhase: .moved,
                isButtonPressed: true,
                samples: [
                    MirageContinuousInputBatch.Sample(
                        timestamp: TimeInterval(index),
                        location: CGPoint(x: CGFloat(index), y: 0.5),
                        pressure: 0.5,
                        stylus: makePointerStylus()
                    ),
                ]
            ))
        }

        queue.activate()
        try await waitForEvents(events, count: 320)

        let xValues = events.read { events in
            events.compactMap { event -> CGFloat? in
                guard case let .pointerSampleBatch(batch) = event else { return nil }
                return batch.samples.first?.location.x
            }
        }
        #expect(xValues == (0 ..< 320).map(CGFloat.init))
    }
}

private func inputMessage(_ event: MirageInputEvent, streamID: StreamID) throws -> ControlMessage {
    let inputMessage = InputEventMessage(streamID: streamID, event: event)
    return ControlMessage(type: .inputEvent, payload: try inputMessage.serializePayload())
}

private func recordInputEvent(from message: ControlMessage, into events: Locked<[MirageInputEvent]>) {
    guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else { return }
    events.withLock { $0.append(inputMessage.event) }
}

private func deliveredScrollEvents(in events: Locked<[MirageInputEvent]>) -> [MirageScrollEvent] {
    events.read { events in
        events.compactMap { event in
            guard case let .scrollWheel(scrollEvent) = event else { return nil }
            return scrollEvent
        }
    }
}

private func waitForEvents(
    _ events: Locked<[MirageInputEvent]>,
    count: Int
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while events.read({ $0.count }) < count, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events.read { $0.count } >= count)
}

private func waitForKeyboardEvent(
    _ events: Locked<[MirageInputEvent]>,
    keyCode: UInt16
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        let didReceive = events.read { events in
            events.contains { event in
                guard case let .keyDown(keyEvent) = event else { return false }
                return keyEvent.keyCode == keyCode
            }
        }
        if didReceive { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Expected keyboard event with keyCode \(keyCode)")
}

private func makeMouseEvent(timestamp: TimeInterval) -> MirageMouseEvent {
    MirageMouseEvent(
        location: CGPoint(x: 0.5, y: 0.5),
        timestamp: timestamp
    )
}

private func makePointerStylus() -> MirageStylusEvent {
    MirageStylusEvent(
        altitudeAngle: 0.8,
        azimuthAngle: 0.2,
        tiltX: 0.1,
        tiltY: 0.2,
        isHovering: false
    )
}
#endif
