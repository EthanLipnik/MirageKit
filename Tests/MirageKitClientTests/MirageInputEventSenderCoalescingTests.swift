//
//  MirageInputEventSenderCoalescingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Coverage for temporary stall-window pointer coalescing on client input send path.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Input Sender Coalescing")
struct MirageInputEventSenderCoalescingTests {
    @Test("Move and drag events are coalesced only while temporary window is active")
    func moveAndDragEventsCoalesceOnlyWithinTemporaryWindow() {
        let sender = MirageInputEventSender()
        let streamID: StreamID = 901
        let moveEvent = MirageInputEvent.mouseMoved(makeMouseEvent())

        sender.activateTemporaryPointerCoalescing(for: streamID, duration: 1.2, now: 100)

        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(moveEvent, streamID: streamID, now: 100.000))
        #expect(sender.shouldDropInputForTemporaryCoalescingForTesting(moveEvent, streamID: streamID, now: 100.004))
        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(moveEvent, streamID: streamID, now: 100.020))

        // Window expires after 1.2s.
        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(moveEvent, streamID: streamID, now: 101.250))
    }

    @Test("Non-pointer events bypass temporary coalescing")
    func nonPointerEventsBypassTemporaryCoalescing() {
        let sender = MirageInputEventSender()
        let streamID: StreamID = 902
        let keyEvent = MirageInputEvent.scrollWheel(
            MirageScrollEvent(deltaX: 0, deltaY: 1, location: CGPoint(x: 0.5, y: 0.5))
        )

        sender.activateTemporaryPointerCoalescing(for: streamID, duration: 1.2, now: 200)

        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(keyEvent, streamID: streamID, now: 200.001))
        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(keyEvent, streamID: streamID, now: 200.004))
    }

    @Test("Temporary coalescing is scoped per stream")
    func temporaryCoalescingIsPerStream() {
        let sender = MirageInputEventSender()
        let throttledStreamID: StreamID = 903
        let bypassedStreamID: StreamID = 904
        let dragEvent = MirageInputEvent.mouseDragged(makeMouseEvent())

        sender.activateTemporaryPointerCoalescing(for: throttledStreamID, duration: 1.2, now: 300)

        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(dragEvent, streamID: throttledStreamID, now: 300.000))
        #expect(sender.shouldDropInputForTemporaryCoalescingForTesting(dragEvent, streamID: throttledStreamID, now: 300.005))

        // No coalescing window was opened for bypassedStreamID.
        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(dragEvent, streamID: bypassedStreamID, now: 300.005))
    }

    private func makeMouseEvent() -> MirageMouseEvent {
        MirageMouseEvent(location: CGPoint(x: 0.5, y: 0.5), timestamp: 0)
    }
}
#endif
