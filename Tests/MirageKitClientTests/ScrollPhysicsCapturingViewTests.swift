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

@Suite("Scroll Physics Capturing View")
struct ScrollPhysicsCapturingViewTests {
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

    @Test("Direct second tap can take drag ownership before scroll")
    func directSecondTapCanTakeDragOwnershipBeforeScroll() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.commitPrimaryClick(at: CGPoint(x: 0.5, y: 0.25), timestamp: 10, clickCount: 1)

        #expect(
            view.isDirectPrimaryClickContinuationCandidate(
                at: CGPoint(x: 160, y: 60),
                timestamp: 10.2
            )
        )
        #expect(
            !view.isDirectPrimaryClickContinuationCandidate(
                at: CGPoint(x: 160, y: 60),
                timestamp: 10.75
            )
        )
        #expect(
            !view.isDirectPrimaryClickContinuationCandidate(
                at: CGPoint(x: 250, y: 60),
                timestamp: 10.2
            )
        )

        view.directTouchInputMode = .dragCursor

        #expect(
            !view.isDirectPrimaryClickContinuationCandidate(
                at: CGPoint(x: 160, y: 60),
                timestamp: 10.2
            )
        )
    }

    @Test("Direct long press drag activates after movement threshold")
    func directLongPressDragActivatesAfterMovementThreshold() {
        #expect(
            !InputCapturingView.directTouchDragActivationExceeded(
                from: .zero,
                to: CGPoint(x: InputCapturingView.dragActivationMovementThresholdPoints - 0.1, y: 0)
            )
        )
        #expect(
            InputCapturingView.directTouchDragActivationExceeded(
                from: .zero,
                to: CGPoint(x: InputCapturingView.dragActivationMovementThresholdPoints, y: 0)
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

    @Test("Unlocked synthetic desktop cursor reuses the tracked local pointer position")
    func unlockedSyntheticDesktopCursorUsesTrackedPointerPosition() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.hideSystemCursor = true
        view.syntheticCursorEnabled = true
        view.cursorIsVisible = true
        view.lastCursorPosition = CGPoint(x: 0.25, y: 0.75)

        view.updateLockedCursorViewVisibility()
        view.updateLockedCursorViewPosition()

        let lockedCursorView = try #require(view.subviews.last as? UIImageView)
        let hotspot = view.currentCursorType.cursorHotspot

        #expect(!lockedCursorView.isHidden)
        #expect(
            lockedCursorView.frame.origin ==
                CGPoint(x: 80 - hotspot.x, y: 180 - hotspot.y)
        )
    }

    @Test("Hidden system cursor shows synthetic cursor before local position is seeded")
    func hiddenSystemCursorShowsSyntheticFallbackBeforeLocalPositionIsSeeded() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.syntheticCursorEnabled = true
        view.hideSystemCursor = true
        view.lastCursorPosition = nil

        view.updateLockedCursorViewVisibility()
        view.updateLockedCursorViewPosition()

        let lockedCursorView = try #require(view.subviews.last as? UIImageView)
        let hotspot = view.currentCursorType.cursorHotspot

        #expect(!lockedCursorView.isHidden)
        #expect(
            lockedCursorView.frame.origin ==
                CGPoint(x: 160 - hotspot.x, y: 120 - hotspot.y)
        )
    }

    @Test("Cursor lock seeds synthetic cursor visibility")
    func cursorLockSeedsSyntheticCursorVisibility() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.syntheticCursorEnabled = true

        view.cursorLockEnabled = true

        let lockedCursorView = try #require(view.subviews.last as? UIImageView)

        #expect(!lockedCursorView.isHidden)
        #expect(view.lockedCursorVisible)
    }

    @Test("Indirect secondary click reuses the tracked pointer location")
    func indirectSecondaryClickReusesTrackedPointerLocation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.lastCursorPosition = CGPoint(x: 0.2, y: 0.8)

        let location = view.resolvedIndirectSecondaryClickLocation(CGPoint(x: 300, y: 12))

        #expect(location == CGPoint(x: 0.2, y: 0.8))
    }

    @Test("Indirect pointer scroll reuses the tracked pointer location")
    func indirectPointerScrollReusesTrackedPointerLocation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.lastCursorPosition = CGPoint(x: 0.35, y: 0.65)

        let location = view.scrollEventLocation(
            source: .indirectPointer,
            phase: .changed,
            momentumPhase: .none
        )

        #expect(location == CGPoint(x: 0.35, y: 0.65))
    }

    @Test("Untracked indirect pointer scroll lets the host choose a target fallback")
    func untrackedIndirectPointerScrollUsesHostFallback() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.lastCursorPosition = nil

        let location = view.scrollEventLocation(
            source: .indirectPointer,
            phase: .changed,
            momentumPhase: .none
        )

        #expect(location == nil)
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
        #expect(!view.directDoubleTapDragGesture.isEnabled)
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

    @Test("Normal direct-touch scroll reuses the tracked pointer location")
    func normalDirectTouchScrollReusesTrackedPointerLocation() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.lastCursorPosition = CGPoint(x: 0.2, y: 0.8)

        let location = view.scrollEventLocation(
            source: .directTouch,
            phase: .changed,
            momentumPhase: .none
        )

        #expect(location == CGPoint(x: 0.2, y: 0.8))
    }

    @Test("Untracked normal direct-touch scroll lets the host choose a target fallback")
    func untrackedNormalDirectTouchScrollUsesHostFallback() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.lastCursorPosition = nil

        let location = view.scrollEventLocation(
            source: .directTouch,
            phase: .changed,
            momentumPhase: .none
        )

        #expect(location == nil)
    }

    private func allowedTouchTypes(for scrollView: UIScrollView) -> Set<Int> {
        Set((scrollView.panGestureRecognizer.allowedTouchTypes ?? []).map(\.intValue))
    }
}
#endif
