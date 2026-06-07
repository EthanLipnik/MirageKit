//
//  InputCapturingView+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    nonisolated static func shouldEmitPassiveHoverMove(
        pointerMoved: Bool,
        isDragging: Bool
    ) -> Bool {
        pointerMoved && !isDragging
    }

    func setupGestureRecognizers() {
        directTouchContactGesture = DirectTouchContactGestureRecognizer()
        directTouchContactGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTouchContactGesture.cancelsTouchesInView = false
        directTouchContactGesture.delaysTouchesBegan = false
        directTouchContactGesture.delaysTouchesEnded = false
        directTouchContactGesture.isAcceptedDirectTouch = { [weak self] touch in
            guard touch.type == .direct else { return false }
            return !(self?.isStylusTouch(touch) ?? false)
        }
        directTouchContactGesture.onTouchesBegan = { [weak self] touches, hadActiveDirectTouchContact in
            self?.handleDirectTouchContactsBegan(
                touches,
                hadActiveDirectTouchContact: hadActiveDirectTouchContact
            )
        }
        directTouchContactGesture.onTouchesEnded = { [weak self] touches, hasRemainingDirectTouchContact in
            self?.handleDirectTouchContactsEnded(
                touches,
                hasRemainingDirectTouchContact: hasRemainingDirectTouchContact
            )
        }
        directTouchContactGesture.onTouchesCancelled = { [weak self] touches, hasRemainingDirectTouchContact in
            self?.handleDirectTouchContactsEnded(
                touches,
                hasRemainingDirectTouchContact: hasRemainingDirectTouchContact
            )
        }
        addGestureRecognizer(directTouchContactGesture)

        // Immediate press/drag for indirect pointer input.
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0
        longPressGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        // Right-click gesture (secondary click with pointer)
        rightClickGesture = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickGesture.buttonMaskRequired = .secondary
        rightClickGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        addGestureRecognizer(rightClickGesture)

        directTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDirectTap(_:)))
        directTapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTapGesture.delegate = self
        addGestureRecognizer(directTapGesture)

        directLongPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDirectLongPress(_:)))
        directLongPressGesture.minimumPressDuration = 0.25
        directLongPressGesture.allowableMovement = Self.dragActivationMovementThresholdPoints
        directLongPressGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directLongPressGesture.delegate = self
        addGestureRecognizer(directLongPressGesture)

        directDoubleTapDragGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleDirectDoubleTapDrag(_:))
        )
        directDoubleTapDragGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directDoubleTapDragGesture.minimumNumberOfTouches = 1
        directDoubleTapDragGesture.maximumNumberOfTouches = 1
        directDoubleTapDragGesture.delegate = self
        addGestureRecognizer(directDoubleTapDragGesture)

        directTapGesture.require(toFail: directLongPressGesture)

        directTwoFingerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDirectTwoFingerTap(_:)))
        directTwoFingerTapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTwoFingerTapGesture.numberOfTouchesRequired = 2
        directTwoFingerTapGesture.delegate = self
        addGestureRecognizer(directTwoFingerTapGesture)

        directTwoFingerDragGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleDirectTwoFingerDrag(_:))
        )
        directTwoFingerDragGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directTwoFingerDragGesture.minimumNumberOfTouches = 2
        directTwoFingerDragGesture.maximumNumberOfTouches = 2
        directTwoFingerDragGesture.delegate = self
        addGestureRecognizer(directTwoFingerDragGesture)

        directTwoFingerTapGesture.require(toFail: directTwoFingerDragGesture)

        // Two-finger swipe gestures for desktop navigation actions.
        setupNavigationSwipeGestures()

        // Direct-touch scrolling for virtual trackpad mode.
        // Native one-finger scrolling uses ScrollPhysicsCapturingView instead.
        scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.allowedScrollTypesMask = [] // Disable trackpad scroll handling
        scrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        scrollGesture.delegate = self
        addGestureRecognizer(scrollGesture)

        // Hover gesture for pointer movement tracking
        hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hoverGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        addGestureRecognizer(hoverGesture)

        // Locked pointer gestures (indirect pointer only)
        lockedPointerPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLockedPointerPan(_:)))
        lockedPointerPanGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        lockedPointerPanGesture.allowedScrollTypesMask = []
        lockedPointerPanGesture.minimumNumberOfTouches = 1
        lockedPointerPanGesture.maximumNumberOfTouches = 1
        lockedPointerPanGesture.delegate = self
        lockedPointerPanGesture.isEnabled = false
        addGestureRecognizer(lockedPointerPanGesture)

        lockedPointerPressGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLockedPointerPress(_:))
        )
        lockedPointerPressGesture.minimumPressDuration = 0
        lockedPointerPressGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        lockedPointerPressGesture.delegate = self
        lockedPointerPressGesture.isEnabled = false
        addGestureRecognizer(lockedPointerPressGesture)

        // Virtual cursor gestures (direct touch trackpad mode)
        virtualCursorPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleVirtualCursorPan(_:)))
        virtualCursorPanGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        virtualCursorPanGesture.minimumNumberOfTouches = 1
        virtualCursorPanGesture.maximumNumberOfTouches = 1
        virtualCursorPanGesture.delegate = self
        addGestureRecognizer(virtualCursorPanGesture)

        virtualCursorLongPressGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleVirtualCursorLongPress(_:))
        )
        virtualCursorLongPressGesture.minimumPressDuration = 0.25
        virtualCursorLongPressGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        virtualCursorLongPressGesture.delegate = self
        addGestureRecognizer(virtualCursorLongPressGesture)

        virtualCursorTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleVirtualCursorTap(_:)))
        virtualCursorTapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        virtualCursorTapGesture.delegate = self
        virtualCursorTapGesture.require(toFail: virtualCursorLongPressGesture)
        addGestureRecognizer(virtualCursorTapGesture)

        virtualCursorRightTapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleVirtualCursorRightTap(_:))
        )
        virtualCursorRightTapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        virtualCursorRightTapGesture.numberOfTouchesRequired = 2
        virtualCursorRightTapGesture.delegate = self
        virtualCursorRightTapGesture.require(toFail: virtualCursorLongPressGesture)
        addGestureRecognizer(virtualCursorRightTapGesture)

        // Rotation gesture for direct touch
        directRotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleDirectRotation(_:)))
        directRotationGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directRotationGesture.delegate = self
        addGestureRecognizer(directRotationGesture)
    }

    // MARK: - Coordinate Helpers

    /// Normalize a point to 0-1 range relative to the currently presented content rect.
    func normalizedLocation(_ point: CGPoint) -> CGPoint {
        Self.normalizedLocation(
            point,
            in: bounds,
            contentRect: resolvedPresentationContentRect()
        )
    }

    func resolvedIndirectSecondaryClickLocation(_ rawLocation: CGPoint) -> CGPoint {
        if cursorLockEnabled {
            setLockedCursorVisible(true)
            return lockedCursorActionPosition()
        }

        if let lastCursorPosition {
            return lastCursorPosition
        }

        return normalizedLocation(rawLocation)
    }

    /// Get combined modifiers from a gesture (at event time) and keyboard state
    /// Polls hardware keyboard for accurate modifier state to avoid stuck modifiers
    func modifiers(from gesture: UIGestureRecognizer) -> MirageModifierFlags {
        let hardwareAvailable = refreshModifiersForInput()
        if hardwareAvailable {
            let snapshot = keyboardModifiers
            sendModifierSnapshotIfNeeded(snapshot)
            return snapshot
        }

        let gestureModifiers = MirageModifierFlags(uiKeyModifierFlags: gesture.modifierFlags)
        resyncModifierState(from: gesture.modifierFlags)
        let snapshot = gestureModifiers.union(keyboardModifiers)
        sendModifierSnapshotIfNeeded(snapshot)
        return snapshot
    }

    // MARK: - Gesture Handlers

    func updatePointerLocationForScrollInteraction(_ rawLocation: CGPoint) -> CGPoint {
        let location = normalizedLocation(rawLocation)

        if usesLockedTrackpadCursor {
            setLockedCursorVisible(true)
            return trackpadCursorActionPosition()
        }

        if cursorLockEnabled {
            updatePointerLocationForLocalContact(location)
            return lockedCursorPosition
        }

        if usesVirtualTrackpad {
            return trackpadCursorPosition()
        }

        updatePointerLocationForLocalContact(location)
        return location
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InputCapturingView: UIGestureRecognizerDelegate {
    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == directDoubleTapDragGesture {
            let rawLocation = gestureRecognizer.location(in: self)
            let candidateLocation: CGPoint
            if let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
                let translation = panGesture.translation(in: self)
                candidateLocation = CGPoint(
                    x: rawLocation.x - translation.x,
                    y: rawLocation.y - translation.y
                )
            } else {
                candidateLocation = rawLocation
            }

            return isDirectPrimaryClickContinuationCandidate(
                at: candidateLocation,
                timestamp: CACurrentMediaTime()
            )
        }

        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let isStylus = isStylusTouch(touch)
        if touch.type == .direct, !isStylus {
            hideCursorForDirectTouchIfNeeded()
            onDirectTouchActivity?()
        }
        guard isStylus else { return true }

        // Route Pencil contact through the dedicated touch handlers only.
        if gestureRecognizer is UIHoverGestureRecognizer { return true }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    )
    -> Bool {
        let directTouchScrollPanGesture = scrollPhysicsView?.directTouchPanGestureRecognizer

        // Allow hover to work with other gestures
        if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer { return true }

        // Allow pinch and rotation to work simultaneously (map-style interaction)
        if (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) ||
            (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }

        if (gestureRecognizer == virtualCursorPanGesture && otherGestureRecognizer == virtualCursorLongPressGesture) ||
            (gestureRecognizer == virtualCursorLongPressGesture && otherGestureRecognizer == virtualCursorPanGesture) {
            return true
        }

        if (gestureRecognizer == directLongPressGesture && otherGestureRecognizer == directTouchScrollPanGesture) ||
            (gestureRecognizer == directTouchScrollPanGesture && otherGestureRecognizer == directLongPressGesture) {
            return true
        }

        if (gestureRecognizer == longPressGesture && otherGestureRecognizer == scrollGesture) ||
            (gestureRecognizer == scrollGesture && otherGestureRecognizer == longPressGesture) {
            return true
        }

        if (gestureRecognizer == lockedPointerPanGesture && otherGestureRecognizer == lockedPointerPressGesture) ||
            (gestureRecognizer == lockedPointerPressGesture && otherGestureRecognizer == lockedPointerPanGesture) {
            return true
        }

        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    )
    -> Bool {
        if gestureRecognizer == directTapGesture,
           let directTouchScrollPanGesture = scrollPhysicsView?.directTouchPanGestureRecognizer,
           otherGestureRecognizer == directTouchScrollPanGesture {
            return true
        }

        // Allow navigation swipe gestures to recognize alongside two-finger drag
        if navigationSwipeGestures.contains(where: { $0 === gestureRecognizer }) {
            return true
        }

        return false
    }
}

// MARK: - Navigation Swipe Gestures

extension InputCapturingView {
    func setupNavigationSwipeGestures() {
        let directions: [UISwipeGestureRecognizer.Direction] = [.left, .right, .up, .down]
        for direction in directions {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleNavigationSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = self
            addGestureRecognizer(swipe)
            navigationSwipeGestures.append(swipe)

            // Swipe should take priority over two-finger drag
            directTwoFingerDragGesture.require(toFail: swipe)
        }
    }

    @objc
    func handleNavigationSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard navigationGesturesEnabled, !actions.isEmpty else { return }

        let actionID: String
        switch gesture.direction {
        case .left:
            actionID = MirageAction.spaceRightID // macOS trackpad convention
        case .right:
            actionID = MirageAction.spaceLeftID
        case .up:
            actionID = MirageAction.missionControlID
        case .down:
            actionID = MirageAction.appExposeID
        default:
            return
        }

        guard let action = actions.first(where: { $0.id == actionID }) else { return }
        onActionTriggered?(action)
    }
}
#endif
