//
//  InputCapturingViewPencilGestureTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import CoreGraphics
import MirageKit
import Testing

@MainActor
@Suite("Input Capturing View Pencil Gestures")
struct InputCapturingViewPencilGestureTests {
    @Test("Double tap configuration toggles dictation")
    func doubleTapConfigurationTogglesDictation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.pencilGestureConfiguration = .init(
            doubleTap: .toggleDictation,
            squeeze: .secondaryClick
        )

        var actions: [MiragePencilGestureAction] = []
        view.onPencilGestureAction = { actions.append($0) }

        view.performPencilGesture(.doubleTap, hoverLocation: nil)

        #expect(actions == [.toggleDictation])
    }

    @Test("Configured secondary click emits right mouse down and up once")
    func secondaryClickEmitsMouseEvents() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.pencilGestureConfiguration = .init(
            doubleTap: .none,
            squeeze: .secondaryClick
        )

        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }

        view.performPencilGesture(.squeeze, hoverLocation: CGPoint(x: 50, y: 25))

        #expect(events.count == 2)

        guard case let .rightMouseDown(mouseDownEvent) = events[0] else {
            Issue.record("Expected right mouse down event")
            return
        }
        guard case let .rightMouseUp(mouseUpEvent) = events[1] else {
            Issue.record("Expected right mouse up event")
            return
        }

        #expect(mouseDownEvent.location == CGPoint(x: 0.25, y: 0.25))
        #expect(mouseUpEvent.location == CGPoint(x: 0.25, y: 0.25))
    }

    @Test("Remote shortcut mapping is surfaced through the Pencil action callback")
    func remoteShortcutTriggersPencilActionCallback() {
        let view = InputCapturingView(frame: .zero)
        let shortcut = MirageClientShortcut(keyCode: 0x15, modifiers: [.command, .shift])

        var actions: [MiragePencilGestureAction] = []
        view.onPencilGestureAction = { actions.append($0) }

        view.performPencilGestureAction(.remoteShortcut(shortcut), hoverLocation: nil)

        #expect(actions == [.remoteShortcut(shortcut)])
    }

    @Test("Pencil hover ignores sub-pixel jitter and forwards meaningful movement")
    func pencilHoverJitterGate() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.lastPencilHoverForwardLocation = CGPoint(x: 0.5, y: 0.5)
        view.lastPencilHoverForwardTime = 10

        #expect(!view.shouldForwardPencilHover(location: CGPoint(x: 0.501, y: 0.5), now: 10.02))
        #expect(!view.shouldForwardPencilHover(location: CGPoint(x: 0.52, y: 0.5), now: 10.001))
        #expect(view.shouldForwardPencilHover(location: CGPoint(x: 0.52, y: 0.5), now: 10.02))
    }

    @Test("Pencil hover batch sender suppresses jitter below threshold")
    func pencilHoverBatchSenderSuppressesJitter() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let stylus = MirageStylusEvent(
            altitudeAngle: .pi / 4,
            azimuthAngle: .pi / 6,
            tiltX: 0.1,
            tiltY: 0.2,
            zOffset: 0.5,
            isHovering: true
        )
        view.lastPencilHoverForwardLocation = CGPoint(x: 0.5, y: 0.5)
        view.lastPencilHoverForwardTime = 10

        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }

        view.sendPencilHoverBatch(
            location: CGPoint(x: 0.501, y: 0.5),
            stylus: stylus,
            modifiers: [],
            now: 10.02
        )

        #expect(events.isEmpty)
    }
}
#endif
