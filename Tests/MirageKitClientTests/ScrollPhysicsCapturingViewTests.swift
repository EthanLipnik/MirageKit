//
//  ScrollPhysicsCapturingViewTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/3/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import Testing
import UIKit

@MainActor
@Suite("Scroll physics view configuration")
struct ScrollPhysicsCapturingViewTests {
    @Test("Embedded scroll views keep their own pan delegates and touch types")
    func embeddedScrollViewsKeepTheirOwnPanDelegatesAndTouchTypes() {
        let view = ScrollPhysicsCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let scrollViews = view.subviews.compactMap { $0 as? UIScrollView }
        let rotationGesture = try #require(
            view.gestureRecognizers?.first(where: { $0 is UIRotationGestureRecognizer })
        )

        #expect(scrollViews.count == 2)

        let directTouchType = Int(UITouch.TouchType.direct.rawValue)
        let indirectPointerTouchType = Int(UITouch.TouchType.indirectPointer.rawValue)
        let indirectTouchType = Int(UITouch.TouchType.indirect.rawValue)
        let pencilTouchType = Int(UITouch.TouchType.pencil.rawValue)

        let directScrollView = try #require(
            scrollViews.first { allowedTouchTypes(for: $0).contains(directTouchType) }
        )
        let indirectScrollView = try #require(
            scrollViews.first { allowedTouchTypes(for: $0).contains(indirectPointerTouchType) }
        )

        #expect(directScrollView.delegate != nil)
        #expect(indirectScrollView.delegate != nil)
        #expect((directScrollView.delegate as AnyObject?) !== directScrollView)
        #expect((indirectScrollView.delegate as AnyObject?) !== indirectScrollView)
        #expect((directScrollView.panGestureRecognizer.delegate as AnyObject?) === directScrollView)
        #expect((indirectScrollView.panGestureRecognizer.delegate as AnyObject?) === indirectScrollView)
        #expect((rotationGesture.delegate as AnyObject?) !== (view as AnyObject?))

        #expect(allowedTouchTypes(for: directScrollView) == [directTouchType])
        #expect(allowedTouchTypes(for: indirectScrollView) == [indirectPointerTouchType, indirectTouchType])
        #expect(!allowedTouchTypes(for: directScrollView).contains(pencilTouchType))
    }

    @Test("Input capturing view gives one-finger direct scroll priority over taps")
    func inputCapturingViewGivesOneFingerDirectScrollPriorityOverTaps() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let directTouchScrollPanGesture = try #require(view.scrollPhysicsView?.directTouchPanGestureRecognizer)

        #expect(
            view.gestureRecognizer(
                view.directTapGesture,
                shouldRequireFailureOf: directTouchScrollPanGesture
            )
        )
        #expect(
            view.gestureRecognizer(
                view.directLongPressGesture,
                shouldRecognizeSimultaneouslyWith: directTouchScrollPanGesture
            )
        )
    }

    @Test("Input capturing view disables the generic pointer long press while cursor lock is active")
    func inputCapturingViewDisablesGenericPointerLongPressWhenCursorLocked() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(view.longPressGesture.isEnabled)
        #expect(!view.lockedPointerPressGesture.isEnabled)

        view.cursorLockEnabled = true

        #expect(!view.longPressGesture.isEnabled)
        #expect(view.lockedPointerPressGesture.isEnabled)
        #expect(view.rightClickGesture.isEnabled)

        view.cursorLockEnabled = false

        #expect(view.longPressGesture.isEnabled)
        #expect(!view.lockedPointerPressGesture.isEnabled)
    }

    @Test("Locked pointer hover ignores large jumps that land on an edge")
    func lockedPointerHoverIgnoresSuspiciousEdgeJump() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(
            view.shouldIgnoreLockedPointerHoverJump(
                from: CGPoint(x: 120, y: 80),
                to: CGPoint(x: 319, y: 239)
            )
        )
        #expect(
            !view.shouldIgnoreLockedPointerHoverJump(
                from: CGPoint(x: 120, y: 80),
                to: CGPoint(x: 150, y: 105)
            )
        )
    }

    @Test("Passive hover only emits movement after actual pointer motion")
    func passiveHoverRequiresActualPointerMotion() {
        #expect(
            !InputCapturingView.shouldEmitPassiveHoverMove(
                pointerMoved: false,
                isDragging: false
            )
        )
        #expect(
            InputCapturingView.shouldEmitPassiveHoverMove(
                pointerMoved: true,
                isDragging: false
            )
        )
    }

    @Test("Passive hover does not emit movement while a drag gesture owns the pointer")
    func passiveHoverSkipsWhileDragging() {
        #expect(
            !InputCapturingView.shouldEmitPassiveHoverMove(
                pointerMoved: true,
                isDragging: true
            )
        )
    }

    @Test("Indirect secondary click reuses the tracked pointer location")
    func indirectSecondaryClickReusesTrackedPointerLocation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.lastCursorPosition = CGPoint(x: 0.2, y: 0.8)

        let location = view.resolvedIndirectSecondaryClickLocation(CGPoint(x: 300, y: 12))

        #expect(location == CGPoint(x: 0.2, y: 0.8))
    }

    @Test("Virtual cursor scroll reanchors to the swipe location")
    func virtualCursorScrollReanchorsToTheSwipeLocation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor

        let location = view.updatePointerLocationForScrollInteraction(CGPoint(x: 160, y: 60))

        #expect(location == CGPoint(x: 0.5, y: 0.25))
        #expect(view.virtualCursorPosition == CGPoint(x: 0.5, y: 0.25))
        #expect(view.lastCursorPosition == CGPoint(x: 0.5, y: 0.25))
    }

    @Test("Cursor-locked drag cursor keeps trackpad gestures enabled")
    func cursorLockedDragCursorKeepsTrackpadGesturesEnabled() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor
        view.cursorLockEnabled = true
        let scrollPhysicsView = try #require(view.scrollPhysicsView)

        #expect(!scrollPhysicsView.directTouchScrollEnabled)
        #expect(view.scrollGesture.isEnabled)
        #expect(view.directRotationGesture.isEnabled)
        #expect(!view.directTapGesture.isEnabled)
        #expect(!view.directLongPressGesture.isEnabled)
        #expect(!view.directTwoFingerTapGesture.isEnabled)
        #expect(!view.directTwoFingerDragGesture.isEnabled)
        #expect(view.virtualCursorPanGesture.isEnabled)
        #expect(view.virtualCursorTapGesture.isEnabled)
        #expect(view.virtualCursorRightTapGesture.isEnabled)
        #expect(view.virtualCursorLongPressGesture.isEnabled)
    }

    @Test("Cursor-locked drag cursor scroll keeps the existing locked cursor position")
    func cursorLockedDragCursorScrollKeepsLockedCursorPosition() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor
        view.cursorLockEnabled = true
        view.allowsExtendedCursorBounds = true
        view.lockedCursorPosition = CGPoint(x: 1.1, y: -0.15)

        let location = view.updatePointerLocationForScrollInteraction(CGPoint(x: 12, y: 20))

        #expect(location == CGPoint(x: 1.1, y: -0.15))
        #expect(view.lockedCursorPosition == CGPoint(x: 1.1, y: -0.15))
    }

    @Test("Normal direct touch moves the remote cursor before scrolling")
    func normalDirectTouchMovesTheRemoteCursorBeforeScrolling() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var receivedEvents: [MirageInputEvent] = []
        view.onInputEvent = { receivedEvents.append($0) }

        view.handleDirectTouchLocationChange(CGPoint(x: 80, y: 60))

        #expect(view.lastCursorPosition == CGPoint(x: 0.25, y: 0.25))
        #expect(receivedEvents.count == 1)
        guard case let .mouseMoved(event) = receivedEvents[0] else {
            Issue.record("Expected a mouseMoved event for direct touch contact")
            return
        }

        #expect(event.location == CGPoint(x: 0.25, y: 0.25))
    }

    @Test("Normal direct touch does not inject mouse-moved while a press gesture owns the pointer")
    func normalDirectTouchSkipsMouseMoveWhilePressGestureOwnsPointer() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var receivedEvents: [MirageInputEvent] = []
        view.onInputEvent = { receivedEvents.append($0) }
        view.directLongPressButtonDown = true

        view.handleDirectTouchLocationChange(CGPoint(x: 80, y: 60))

        #expect(view.lastCursorPosition == CGPoint(x: 0.25, y: 0.25))
        #expect(receivedEvents.isEmpty)
    }

    private func allowedTouchTypes(for scrollView: UIScrollView) -> Set<Int> {
        Set((scrollView.panGestureRecognizer.allowedTouchTypes ?? []).map(\.intValue))
    }
}
#endif
