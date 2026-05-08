//
//  HostInputMessageSchedulerScrollTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
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

        let scrollEvents: [MirageScrollEvent] = events.read { events in
            events.compactMap { event in
                guard case let .scrollWheel(scrollEvent) = event else { return nil }
                return scrollEvent
            }
        }
        #expect(scrollEvents.count == 1)
        #expect(scrollEvents.first?.deltaX == 4)
        #expect(scrollEvents.first?.deltaY == 6)
        #expect(scrollEvents.first?.phase == .changed)
        #expect(scrollEvents.first?.timestamp == 2)
    }

    @Test("Legacy scroll messages keep replacement behavior instead of merging")
    func legacyScrollMessagesKeepReplacementBehaviorInsteadOfMerging() async throws {
        let streamID: StreamID = 702
        let queue = DispatchQueue(label: "com.mirage.tests.host-input-scroll-legacy", attributes: .initiallyInactive)
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

        let scrollEvents: [MirageScrollEvent] = events.read { events in
            events.compactMap { event in
                guard case let .scrollWheel(scrollEvent) = event else { return nil }
                return scrollEvent
            }
        }
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
}

private func inputMessage(_ event: MirageInputEvent, streamID: StreamID) throws -> ControlMessage {
    let inputMessage = InputEventMessage(streamID: streamID, event: event)
    return ControlMessage(type: .inputEvent, payload: try inputMessage.serializePayload())
}

private func recordInputEvent(from message: ControlMessage, into events: Locked<[MirageInputEvent]>) {
    guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else { return }
    events.withLock { $0.append(inputMessage.event) }
}

private func waitForEvents(
    _ events: Locked<[MirageInputEvent]>,
    count: Int
) async throws {
    let deadline = Date().addingTimeInterval(2)
    while events.read({ $0.count }) < count, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events.read { $0.count } >= count)
}

private func waitForKeyboardEvent(
    _ events: Locked<[MirageInputEvent]>,
    keyCode: UInt16
) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
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
#endif
