//
//  ScrollPhysicsCapturingViewTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/3/26.
//

#if os(iOS) || os(visionOS)
import MirageKit
@testable import MirageKitClient
import Testing
import UIKit
import MirageInput

@Suite("Scroll Physics Capturing View")
struct ScrollPhysicsCapturingViewTests {
    @Test("Input capturing view keeps direct scroll separate from taps and held drags")
    func inputCapturingViewKeepsDirectScrollSeparateFromTapsAndHeldDrags() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let directTouchScrollPanGesture = try #require(view.scrollPhysicsView?.directTouchPanGestureRecognizer)

        #expect(
            view.gestureRecognizer(
                view.directTapGesture,
                shouldRequireFailureOf: directTouchScrollPanGesture
            )
        )
        #expect(
            !view.gestureRecognizer(
                view.directLongPressGesture,
                shouldRecognizeSimultaneouslyWith: directTouchScrollPanGesture
            )
        )
    }

    @Test("Unified scroll layer accepts direct and indirect scrolling in normal mode")
    func unifiedScrollLayerAcceptsDirectAndIndirectScrollingInNormalMode() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal

        let directTouchScrollPanGesture = try #require(view.scrollPhysicsView?.directTouchPanGestureRecognizer)
        let allowedTouchTypes = allowedTouchTypes(for: directTouchScrollPanGesture)

        #expect(allowedTouchTypes.contains(UITouch.TouchType.direct.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.indirectPointer.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.indirect.rawValue))
    }

    @Test("Unified scroll layer keeps indirect scrolling in virtual trackpad mode")
    func unifiedScrollLayerKeepsIndirectScrollingInVirtualTrackpadMode() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor

        let directTouchScrollPanGesture = try #require(view.scrollPhysicsView?.directTouchPanGestureRecognizer)
        let allowedTouchTypes = allowedTouchTypes(for: directTouchScrollPanGesture)

        #expect(!allowedTouchTypes.contains(UITouch.TouchType.direct.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.indirectPointer.rawValue))
        #expect(allowedTouchTypes.contains(UITouch.TouchType.indirect.rawValue))
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

    @Test("Direct touch activity hides local cursor presentation in direct mode")
    func directTouchActivityHidesLocalCursorPresentationInDirectMode() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal

        view.hideCursorForDirectTouchIfNeeded()

        #expect(view.cursorHiddenForDirectTouch)
        #expect(view.cursorHiddenByLocalInput)
    }

    @Test("Direct touch activity does not hide the simulated trackpad cursor")
    func directTouchActivityDoesNotHideSimulatedTrackpadCursor() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor

        view.hideCursorForDirectTouchIfNeeded()

        #expect(view.cursorHiddenForDirectTouch == false)
        #expect(!view.virtualCursorView.isHidden)
    }

    @Test("Simulated trackpad mode clears direct touch cursor suppression")
    func simulatedTrackpadModeClearsDirectTouchCursorSuppression() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.hideCursorForDirectTouchIfNeeded()

        view.directTouchInputMode = .dragCursor

        #expect(view.cursorHiddenForDirectTouch == false)
        #expect(!view.virtualCursorView.isHidden)

        view.directTouchInputMode = .normal

        #expect(view.cursorHiddenForDirectTouch == false)
    }

    @Test("Cursor driven movement clears direct touch cursor suppression")
    func cursorDrivenMovementClearsDirectTouchCursorSuppression() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.hideCursorForDirectTouchIfNeeded()

        view.revealCursorAfterCursorDrivenMovement()

        #expect(view.cursorHiddenForDirectTouch == false)
        #expect(view.cursorHiddenByLocalInput == false)
    }

    @Test("Direct touch scroll begin keeps direct touch cursor suppression")
    func directTouchScrollBeginKeepsDirectTouchCursorSuppression() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.hideCursorForDirectTouchIfNeeded()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 80, y: 60))

        #expect(view.cursorHiddenForDirectTouch)
    }

    @Test("Direct touch cursor suppression hides unlocked synthetic cursor")
    func directTouchCursorSuppressionHidesUnlockedSyntheticCursor() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.hideSystemCursor = true
        view.syntheticCursorEnabled = true
        view.lastCursorPosition = CGPoint(x: 0.25, y: 0.75)
        view.hideCursorForDirectTouchIfNeeded()

        view.updateLockedCursorViewVisibility()

        let lockedCursorView = try #require(view.subviews.last as? UIImageView)
        #expect(lockedCursorView.isHidden)

        view.revealCursorAfterCursorDrivenMovement()

        #expect(!lockedCursorView.isHidden)
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

    @Test("Virtual cursor scroll keeps the existing cursor position")
    func virtualCursorScrollKeepsExistingCursorPosition() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor
        view.updateVirtualCursorPosition(CGPoint(x: 0.2, y: 0.75), updateVisibility: true)

        let location = view.updatePointerLocationForScrollInteraction(CGPoint(x: 160, y: 60))

        #expect(location == CGPoint(x: 0.2, y: 0.75))
        #expect(view.virtualCursorPosition == CGPoint(x: 0.2, y: 0.75))
        #expect(view.lastCursorPosition == CGPoint(x: 0.2, y: 0.75))
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

    @Test("Normal direct scroll begin moves the host cursor immediately")
    func normalDirectScrollBeginMovesHostCursorImmediately() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        var events: [MirageInput.MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 80, y: 60))

        let expectedLocation = CGPoint(x: 0.25, y: 0.25)
        #expect(view.lastCursorPosition == expectedLocation)
        #expect(view.scrollEventLocation(source: .directTouch) == expectedLocation)

        let event = try #require(events.first)
        guard case let .mouseMoved(mouseEvent) = event else {
            Issue.record("Expected direct scroll begin to emit mouseMoved")
            return
        }
        #expect(mouseEvent.location == expectedLocation)
    }

    @Test("Normal direct scroll begin replaces a stale scroll anchor")
    func normalDirectScrollBeginReplacesStaleScrollAnchor() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.directTouchScrollAnchorLocation = CGPoint(x: 0.25, y: 0.25)
        view.lastCursorPosition = CGPoint(x: 0.25, y: 0.25)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 240, y: 120))

        let expectedLocation = CGPoint(x: 0.75, y: 0.5)
        #expect(view.lastCursorPosition == expectedLocation)
        #expect(view.scrollEventLocation(source: .directTouch) == expectedLocation)

        let event = try #require(events.first)
        guard case let .mouseMoved(mouseEvent) = event else {
            Issue.record("Expected direct scroll begin to emit mouseMoved")
            return
        }
        #expect(mouseEvent.location == expectedLocation)
    }

    @Test("Normal direct scroll begin ends interrupted momentum before moving cursor")
    func normalDirectScrollBeginEndsInterruptedMomentumBeforeMovingCursor() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.directTouchScrollAnchorLocation = CGPoint(x: 0.25, y: 0.25)
        view.directTouchScrollMomentumActive = true
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 240, y: 120))

        let expectedLocation = CGPoint(x: 0.75, y: 0.5)
        #expect(view.directTouchScrollAnchorLocation == expectedLocation)
        #expect(view.directTouchScrollMomentumActive == false)
        #expect(events.count == 2)

        guard case let .scrollWheel(endEvent) = events.first else {
            Issue.record("Expected interrupted momentum end before cursor move")
            return
        }
        #expect(endEvent.deltaX == 0)
        #expect(endEvent.deltaY == 0)
        #expect(endEvent.location == CGPoint(x: 0.25, y: 0.25))
        #expect(endEvent.phase == .none)
        #expect(endEvent.momentumPhase == .ended)

        guard case let .mouseMoved(mouseEvent) = events.last else {
            Issue.record("Expected direct scroll begin to emit mouseMoved after momentum end")
            return
        }
        #expect(mouseEvent.location == expectedLocation)
    }

    @Test("Fresh direct contact does not early reanchor without direct deceleration")
    func freshDirectContactDoesNotEarlyReanchorWithoutDirectDeceleration() {
        #expect(ScrollPhysicsCapturingView.shouldPrepareDirectTouchScrollBegin(
            directTouchScrollEnabled: true,
            hadActiveDirectTouchContact: false
        ))
        #expect(!ScrollPhysicsCapturingView.shouldEmitEarlyDirectTouchBegin(
            activeInputSource: .directTouch,
            hadActiveDirectTouchContact: false,
            isDecelerating: false
        ))
        #expect(!ScrollPhysicsCapturingView.shouldEmitEarlyDirectTouchBegin(
            activeInputSource: .indirectPointer,
            hadActiveDirectTouchContact: false,
            isDecelerating: true
        ))
    }

    @Test("New direct contact during direct deceleration early reanchors")
    func newDirectContactDuringDirectDecelerationEarlyReanchors() {
        #expect(ScrollPhysicsCapturingView.shouldEmitEarlyDirectTouchBegin(
            activeInputSource: .directTouch,
            hadActiveDirectTouchContact: false,
            isDecelerating: true
        ))
    }

    @Test("Additional direct contact does not early reanchor")
    func additionalDirectContactDoesNotEarlyReanchor() {
        #expect(!ScrollPhysicsCapturingView.shouldPrepareDirectTouchScrollBegin(
            directTouchScrollEnabled: true,
            hadActiveDirectTouchContact: true
        ))
        #expect(!ScrollPhysicsCapturingView.shouldPrepareDirectTouchScrollBegin(
            directTouchScrollEnabled: true,
            hadActiveDirectTouchContact: false,
            newDirectTouchContactCount: 2
        ))
        #expect(!ScrollPhysicsCapturingView.shouldEmitEarlyDirectTouchBegin(
            activeInputSource: .directTouch,
            hadActiveDirectTouchContact: true,
            isDecelerating: true
        ))
    }

    @Test("Direct contact start prepares scroll anchor before UIKit dragging")
    func directContactStartPreparesScrollAnchorBeforeUIKitDragging() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        let scrollPhysicsView = try #require(view.scrollPhysicsView)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        scrollPhysicsView.prepareDirectTouchScrollBegin(at: CGPoint(x: 240, y: 120))

        let expectedLocation = CGPoint(x: 0.75, y: 0.5)
        #expect(view.lastCursorPosition == expectedLocation)
        #expect(view.scrollEventLocation(source: .directTouch) == expectedLocation)
        #expect(events.count == 1)

        guard case let .mouseMoved(mouseEvent) = events.first else {
            Issue.record("Expected direct contact start to emit mouseMoved")
            return
        }
        #expect(mouseEvent.location == expectedLocation)
    }

    @Test("Prepared direct contact clears anchor if it ends before dragging")
    func preparedDirectContactClearsAnchorIfItEndsBeforeDragging() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        let scrollPhysicsView = try #require(view.scrollPhysicsView)

        scrollPhysicsView.prepareDirectTouchScrollBegin(at: CGPoint(x: 240, y: 120))
        #expect(view.directTouchScrollAnchorLocation == CGPoint(x: 0.75, y: 0.5))

        #expect(scrollPhysicsView.finishPreparedDirectTouchBeginWithoutDraggingIfNeeded())

        #expect(view.directTouchScrollAnchorLocation == nil)
        #expect(view.lastCursorPosition == CGPoint(x: 0.75, y: 0.5))
    }

    @Test("Early direct begin suppresses duplicate UIKit drag begin")
    func earlyDirectBeginSuppressesDuplicateUIKitDragBegin() {
        let scrollView = ScrollPhysicsCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var scrolls: [(phase: MirageScrollPhase, momentumPhase: MirageScrollPhase, source: ScrollPhysicsCapturingView.InputSource)] = []
        scrollView.onScroll = { _, _, phase, momentumPhase, source in
            scrolls.append((phase, momentumPhase, source))
        }

        scrollView.emitEarlyDirectTouchBegin(at: CGPoint(x: 120, y: 80))

        #expect(scrolls.count == 1)
        #expect(scrolls.first?.phase == .began)
        #expect(scrolls.first?.momentumPhase == .none)
        #expect(scrolls.first?.source == .directTouch)
        #expect(scrollView.consumeEarlyDirectTouchBeginIfNeeded(for: .directTouch))
        #expect(!scrollView.consumeEarlyDirectTouchBeginIfNeeded(for: .directTouch))
    }

    @Test("Prepared direct anchor suppresses duplicate UIKit cursor move")
    func preparedDirectAnchorSuppressesDuplicateUIKitCursorMove() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        let scrollPhysicsView = try #require(view.scrollPhysicsView)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        scrollPhysicsView.prepareDirectTouchScrollBegin(at: CGPoint(x: 240, y: 120))

        #expect(scrollPhysicsView.consumePreparedDirectTouchAnchorIfNeeded(for: .directTouch))
        #expect(!scrollPhysicsView.consumePreparedDirectTouchAnchorIfNeeded(for: .directTouch))
        #expect(events.count == 1)
    }

    @Test("Early direct begin ends if contact finishes before dragging")
    func earlyDirectBeginEndsIfContactFinishesBeforeDragging() {
        let scrollView = ScrollPhysicsCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var phases: [MirageScrollPhase] = []
        scrollView.onScroll = { _, _, phase, _, _ in
            phases.append(phase)
        }

        scrollView.emitEarlyDirectTouchBegin(at: CGPoint(x: 120, y: 80))
        #expect(scrollView.finishEarlyDirectTouchBeginWithoutDraggingIfNeeded())

        #expect(phases == [.began, .ended])
    }

    @Test("Early direct begin ends interrupted momentum then starts at new anchor")
    func earlyDirectBeginEndsInterruptedMomentumThenStartsAtNewAnchor() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.directTouchScrollAnchorLocation = CGPoint(x: 0.25, y: 0.25)
        view.directTouchScrollMomentumActive = true
        let scrollPhysicsView = try #require(view.scrollPhysicsView)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        scrollPhysicsView.emitEarlyDirectTouchBegin(at: CGPoint(x: 240, y: 120))

        let expectedLocation = CGPoint(x: 0.75, y: 0.5)
        #expect(events.count == 3)
        #expect(view.directTouchScrollAnchorLocation == expectedLocation)
        #expect(view.scrollEventLocation(source: .directTouch) == expectedLocation)

        guard case let .scrollWheel(endEvent) = events.first else {
            Issue.record("Expected interrupted momentum end before cursor move")
            return
        }
        #expect(endEvent.location == CGPoint(x: 0.25, y: 0.25))
        #expect(endEvent.momentumPhase == .ended)

        guard case let .mouseMoved(mouseEvent) = events.dropFirst().first else {
            Issue.record("Expected cursor move before direct scroll begin")
            return
        }
        #expect(mouseEvent.location == expectedLocation)

        guard case let .scrollWheel(beginEvent) = events.last else {
            Issue.record("Expected direct scroll begin after cursor move")
            return
        }
        #expect(beginEvent.location == expectedLocation)
        #expect(beginEvent.phase == .began)
        #expect(beginEvent.momentumPhase == .none)
    }

    @Test("Direct-touch scroll lifecycle tracks active momentum")
    func directTouchScrollLifecycleTracksActiveMomentum() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.directTouchScrollAnchorLocation = CGPoint(x: 0.25, y: 0.25)

        view.clearDirectTouchScrollAnchorIfNeeded(
            source: .directTouch,
            phase: .ended,
            momentumPhase: .began
        )

        #expect(view.directTouchScrollMomentumActive)
        #expect(view.directTouchScrollAnchorLocation == CGPoint(x: 0.25, y: 0.25))

        view.clearDirectTouchScrollAnchorIfNeeded(
            source: .directTouch,
            phase: .none,
            momentumPhase: .ended
        )

        #expect(view.directTouchScrollMomentumActive == false)
        #expect(view.directTouchScrollAnchorLocation == nil)
    }

    @Test("Direct-touch scroll lifecycle metadata bypasses native scroll preference")
    func directTouchScrollLifecycleMetadataBypassesNativeScrollPreference() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: MirageNativeScrollEventMetadataPreference.defaultsKey)
        defaults.set(false, forKey: MirageNativeScrollEventMetadataPreference.defaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: MirageNativeScrollEventMetadataPreference.defaultsKey)
            } else {
                defaults.removeObject(forKey: MirageNativeScrollEventMetadataPreference.defaultsKey)
            }
        }

        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let event = try #require(view.makeScrollEvent(
            deltaX: 0,
            deltaY: 0,
            location: CGPoint(x: 0.5, y: 0.5),
            phase: .began,
            modifiers: [],
            isPrecise: true,
            preservePhaseMetadata: true
        ))

        #expect(event.phase == .began)
        #expect(event.momentumPhase == .none)
    }

    @Test("Simulated trackpad scroll begin does not emit a direct cursor move")
    func simulatedTrackpadScrollBeginDoesNotEmitDirectCursorMove() {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .dragCursor
        var events: [MirageInput.MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 80, y: 60))

        #expect(events.isEmpty)
        #expect(view.lastCursorPosition == view.virtualCursorPosition)
    }

    @Test("Cursor locked direct scroll begin moves the locked cursor immediately")
    func cursorLockedDirectScrollBeginMovesLockedCursorImmediately() throws {
        let view = InputCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.directTouchInputMode = .normal
        view.cursorLockEnabled = true
        var events: [MirageInput.MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        events.removeAll()

        view.handleDirectTouchScrollBegan(at: CGPoint(x: 240, y: 120))

        let expectedLocation = CGPoint(x: 0.75, y: 0.5)
        #expect(view.lockedCursorPosition == expectedLocation)
        #expect(view.lastCursorPosition == expectedLocation)

        let event = try #require(events.first)
        guard case let .mouseMoved(mouseEvent) = event else {
            Issue.record("Expected cursor locked direct scroll begin to emit mouseMoved")
            return
        }
        #expect(mouseEvent.location == expectedLocation)
    }

    private func allowedTouchTypes(for recognizer: UIGestureRecognizer) -> Set<Int> {
        Set((recognizer.allowedTouchTypes ?? []).map(\.intValue))
    }
}
#endif
