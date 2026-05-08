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

    @Test("Input sender tracks probe-gating interaction")
    func inputSenderTracksProbeGatingInteraction() {
        let sender = MirageInputEventSender()

        sender.recordInteractionForTesting(.mouseMoved(makeMouseEvent()), now: 400)

        #expect(sender.hasRecentInteraction(within: 3, now: 402.9))
        #expect(!sender.hasRecentInteraction(within: 3, now: 403.1))
    }

    @Test("Window resize does not count as probe-gating interaction")
    func windowResizeDoesNotCountAsProbeGatingInteraction() {
        let sender = MirageInputEventSender()

        sender.recordInteractionForTesting(
            .windowResize(MirageResizeEvent(windowID: 1, newSize: CGSize(width: 800, height: 600), scaleFactor: 2)),
            now: 500
        )

        #expect(!sender.hasRecentInteraction(within: 3, now: 501))
    }

    @Test("Temporary pointer coalescing drops hover but not Pencil contact batches")
    func temporaryPointerCoalescingKeepsPencilContactBatches() {
        let sender = MirageInputEventSender()
        let streamID: StreamID = 906
        let hoverEvent = MirageInputEvent.pointerSampleBatch(makePointerBatch(phase: .hover, isHovering: true))
        let contactEvent = MirageInputEvent.pointerSampleBatch(makePointerBatch(phase: .moved, isHovering: false))

        sender.activateTemporaryPointerCoalescing(for: streamID, duration: 1.2, now: 600)

        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(hoverEvent, streamID: streamID, now: 600.000))
        #expect(sender.shouldDropInputForTemporaryCoalescingForTesting(hoverEvent, streamID: streamID, now: 600.004))
        #expect(!sender.shouldDropInputForTemporaryCoalescingForTesting(contactEvent, streamID: streamID, now: 600.005))
    }

    @Test("Slow best-effort sends replace hover while preserving Pencil contact order")
    func slowBestEffortSendsReplaceHoverAndPreserveContactOrder() async throws {
        let sender = MirageInputEventSender()
        let recorder = PointerBatchRecorder()
        let streamID: StreamID = 907

        sender.updateSendHandler { data, _ in
            guard case let .success(message, _) = ControlMessage.deserialize(from: data) else {
                Issue.record("Expected a serialized control message")
                return
            }
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            if case let .pointerSampleBatch(batch) = inputMessage.event {
                await recorder.append(batch)
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        sender.sendInputFireAndForget(
            .pointerSampleBatch(makePointerBatch(phase: .began, sampleX: 0, isButtonPressed: true)),
            streamID: streamID
        )
        for index in 0 ..< 80 {
            sender.sendInputFireAndForget(
                .pointerSampleBatch(makePointerBatch(phase: .hover, sampleX: CGFloat(index), isHovering: true)),
                streamID: streamID
            )
        }
        for index in 0 ..< 6 {
            sender.sendInputFireAndForget(
                .pointerSampleBatch(makePointerBatch(
                    phase: .moved,
                    sampleX: CGFloat(index),
                    isButtonPressed: true
                )),
                streamID: streamID
            )
        }
        sender.sendInputFireAndForget(
            .pointerSampleBatch(makePointerBatch(phase: .ended, sampleX: 7, isButtonPressed: false)),
            streamID: streamID
        )

        try await Task.sleep(for: .milliseconds(600))

        let batches = await recorder.snapshot()
        #expect(batches.first?.phase == .began)
        #expect(batches.last?.phase == .ended)
        #expect(batches.filter { $0.phase == .hover }.count < 80)
        #expect(batches.filter { $0.phase == .moved }.count == 6)
        let movedXValues = batches.filter { $0.phase == .moved }.compactMap { $0.samples.first?.location.x }
        #expect(movedXValues == [
            CGFloat(0), CGFloat(1), CGFloat(2), CGFloat(3), CGFloat(4), CGFloat(5),
        ])
    }

    @Test("Native continuous scroll events merge by summing deltas")
    func nativeContinuousScrollEventsMergeBySummingDeltas() async throws {
        let sender = MirageInputEventSender()
        let recorder = InputEventRecorder()
        let streamID: StreamID = 908
        let location = CGPoint(x: 0.5, y: 0.5)

        sender.updateSendHandler { data, _ in
            guard case let .success(message, _) = ControlMessage.deserialize(from: data) else {
                Issue.record("Expected a serialized control message")
                return
            }
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            await recorder.append(inputMessage.event)
            try await Task.sleep(for: .milliseconds(20))
        }

        sender.sendInputFireAndForget(.keyDown(MirageKeyEvent(keyCode: 0x7E)), streamID: streamID)
        sender.sendInputFireAndForget(.scrollWheel(MirageScrollEvent(
            deltaX: 1,
            deltaY: 2,
            location: location,
            phase: .changed,
            isPrecise: true,
            timestamp: 1
        )), streamID: streamID)
        sender.sendInputFireAndForget(.scrollWheel(MirageScrollEvent(
            deltaX: 3,
            deltaY: 4,
            location: location,
            phase: .changed,
            isPrecise: true,
            timestamp: 2
        )), streamID: streamID)

        try await Task.sleep(for: .milliseconds(150))

        let scrollEvents = await recorder.scrollEvents()
        #expect(scrollEvents.count == 1)
        #expect(scrollEvents.first?.deltaX == 4)
        #expect(scrollEvents.first?.deltaY == 6)
        #expect(scrollEvents.first?.phase == .changed)
        #expect(scrollEvents.first?.timestamp == 2)
    }

    @Test("Legacy scroll events keep replacement behavior instead of merging")
    func legacyScrollEventsKeepReplacementBehaviorInsteadOfMerging() async throws {
        let sender = MirageInputEventSender()
        let recorder = InputEventRecorder()
        let streamID: StreamID = 909
        let location = CGPoint(x: 0.5, y: 0.5)

        sender.updateSendHandler { data, _ in
            guard case let .success(message, _) = ControlMessage.deserialize(from: data) else {
                Issue.record("Expected a serialized control message")
                return
            }
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            await recorder.append(inputMessage.event)
            try await Task.sleep(for: .milliseconds(20))
        }

        sender.sendInputFireAndForget(.keyDown(MirageKeyEvent(keyCode: 0x7E)), streamID: streamID)
        sender.sendInputFireAndForget(.scrollWheel(MirageScrollEvent(
            deltaX: 1,
            deltaY: 2,
            location: location,
            isPrecise: true,
            timestamp: 1
        )), streamID: streamID)
        sender.sendInputFireAndForget(.scrollWheel(MirageScrollEvent(
            deltaX: 3,
            deltaY: 4,
            location: location,
            isPrecise: true,
            timestamp: 2
        )), streamID: streamID)

        try await Task.sleep(for: .milliseconds(150))

        let scrollEvents = await recorder.scrollEvents()
        #expect(scrollEvents.count == 1)
        #expect(scrollEvents.first?.deltaX == 3)
        #expect(scrollEvents.first?.deltaY == 4)
        #expect(scrollEvents.first?.phase == MirageScrollPhase.none)
        #expect(scrollEvents.first?.timestamp == 2)
    }

    @Test("Only replaceable realtime input uses droppable delivery mode")
    func onlyReplaceableRealtimeInputUsesDroppableDeliveryMode() async throws {
        let sender = MirageInputEventSender()
        let recorder = DeliveryModeRecorder()
        let streamID: StreamID = 910
        let keyEvent = MirageKeyEvent(keyCode: 0x7E, modifiers: [])

        sender.updateSendHandler { _, deliveryMode in
            await recorder.append(deliveryMode)
        }

        sender.sendInputFireAndForget(.mouseMoved(makeMouseEvent()), streamID: streamID)
        sender.sendInputFireAndForget(.pointerSampleBatch(makePointerBatch(phase: .hover, isHovering: true)), streamID: streamID)
        sender.sendInputFireAndForget(.keyDown(keyEvent), streamID: streamID)
        sender.sendInputFireAndForget(.scrollWheel(
            MirageScrollEvent(deltaX: 0, deltaY: 1, location: CGPoint(x: 0.5, y: 0.5))
        ), streamID: streamID)

        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.snapshot() == [
            .droppableRealtime,
            .droppableRealtime,
            .orderedBestEffort,
            .orderedBestEffort,
        ])
    }

    private func makeMouseEvent() -> MirageMouseEvent {
        MirageMouseEvent(location: CGPoint(x: 0.5, y: 0.5), timestamp: 0)
    }

    private func makePointerBatch(
        phase: MiragePointerSampleBatchPhase,
        sampleX: CGFloat = 0.5,
        isButtonPressed: Bool = false,
        isHovering: Bool = false
    ) -> MiragePointerSampleBatch {
        let sample = MiragePointerSample(
            location: CGPoint(x: sampleX, y: 0.5),
            pressure: isButtonPressed ? 0.5 : 0,
            stylus: MirageStylusEvent(
                altitudeAngle: .pi / 4,
                azimuthAngle: .pi / 6,
                tiltX: 0.1,
                tiltY: 0.2,
                isHovering: isHovering
            ),
            timestamp: TimeInterval(sampleX)
        )
        return MiragePointerSampleBatch(
            phase: phase,
            modifiers: [],
            clickCount: isButtonPressed ? 1 : 0,
            isButtonPressed: isButtonPressed,
            samples: [sample],
            timestamp: TimeInterval(sampleX)
        )
    }
}

private actor PointerBatchRecorder {
    private var batches: [MiragePointerSampleBatch] = []

    func append(_ batch: MiragePointerSampleBatch) {
        batches.append(batch)
    }

    func snapshot() -> [MiragePointerSampleBatch] {
        batches
    }
}

private actor InputEventRecorder {
    private var events: [MirageInputEvent] = []

    func append(_ event: MirageInputEvent) {
        events.append(event)
    }

    func scrollEvents() -> [MirageScrollEvent] {
        events.compactMap { event in
            guard case let .scrollWheel(scrollEvent) = event else { return nil }
            return scrollEvent
        }
    }
}

private actor DeliveryModeRecorder {
    private var modes: [MirageInputEventSender.DeliveryMode] = []

    func append(_ mode: MirageInputEventSender.DeliveryMode) {
        modes.append(mode)
    }

    func snapshot() -> [MirageInputEventSender.DeliveryMode] {
        modes
    }
}
#endif
