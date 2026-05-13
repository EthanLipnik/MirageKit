//
//  InputCapturingView+DirectTouchGestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    @objc
    func handleDirectTap(_ gesture: UITapGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopTouchScrollDeceleration()

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForLocalContact(location)

        let now = CACurrentMediaTime()
        let clickCount = nextPrimaryClickCount(at: location, timestamp: now)
        currentClickCount = clickCount

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: clickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.mouseDown(mouseEvent))
        onInputEvent?(.mouseUp(mouseEvent))
        commitPrimaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    @objc
    func handleDirectLongPress(_ gesture: UILongPressGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if swallowingDirectLongPressForCursorRecapture {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                swallowingDirectLongPressForCursorRecapture = false
            }
            return
        }
        if gesture.state == .began, requestCursorLockRecaptureIfNeeded() {
            swallowingDirectLongPressForCursorRecapture = true
            return
        }

        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        updatePointerLocationForLocalContact(location)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            stopTouchScrollDeceleration()
            resetPrimaryClickTracking()
            isDragging = false
            directLongPressButtonDown = false
            directLongPressStartPoint = rawLocation
            lastPanLocation = location

        case .changed:
            let shouldActivateDrag = Self.directTouchDragActivationExceeded(
                from: directLongPressStartPoint,
                to: rawLocation
            )
            guard directLongPressButtonDown || shouldActivateDrag else {
                return
            }
            if !directLongPressButtonDown {
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: lastPanLocation,
                    clickCount: 1,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseDown(mouseEvent))
                directLongPressButtonDown = true
            }
            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
                stopTouchScrollDeceleration()
                revealCursorAfterPointerMovement()
                isDragging = true
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseDragged(mouseEvent))
                lastPanLocation = location
            }

        case .ended,
             .cancelled,
             .failed:
            guard directLongPressButtonDown else {
                if gesture.state == .ended {
                    stopTouchScrollDeceleration()
                    let now = CACurrentMediaTime()
                    let clickCount = nextSecondaryClickCount(at: location, timestamp: now)
                    currentRightClickCount = clickCount
                    let mouseEvent = MirageMouseEvent(
                        button: .right,
                        location: location,
                        clickCount: clickCount,
                        modifiers: eventModifiers
                    )
                    onInputEvent?(.rightMouseDown(mouseEvent))
                    onInputEvent?(.rightMouseUp(mouseEvent))
                    commitSecondaryClick(at: location, timestamp: now, clickCount: clickCount)
                }
                isDragging = false
                return
            }

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            directLongPressButtonDown = false
            isDragging = false

        default:
            break
        }
    }

    @objc
    func handleDirectDoubleTapDrag(_ gesture: UIPanGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if swallowingDirectDoubleTapDragForCursorRecapture {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                swallowingDirectDoubleTapDragForCursorRecapture = false
            }
            return
        }
        if gesture.state == .began, requestCursorLockRecaptureIfNeeded() {
            swallowingDirectDoubleTapDragForCursorRecapture = true
            return
        }

        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        updatePointerLocationForLocalContact(location)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            stopTouchScrollDeceleration()
            let translation = gesture.translation(in: self)
            let startRawLocation = CGPoint(
                x: rawLocation.x - translation.x,
                y: rawLocation.y - translation.y
            )
            let startLocation = normalizedLocation(startRawLocation)
            updatePointerLocationForLocalContact(startLocation)
            let now = CACurrentMediaTime()
            currentClickCount = nextPrimaryClickCount(at: startLocation, timestamp: now)
            directDoubleTapDragButtonDown = true
            isDragging = false
            lastPanLocation = startLocation

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: startLocation,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
                updatePointerLocationForLocalContact(location)
                revealCursorAfterPointerMovement()
                isDragging = true
                let dragEvent = MirageMouseEvent(
                    button: .left,
                    location: location,
                    clickCount: currentClickCount,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseDragged(dragEvent))
                lastPanLocation = location
            }

        case .changed:
            guard directDoubleTapDragButtonDown else { return }
            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
                stopTouchScrollDeceleration()
                if !isDragging { resetPrimaryClickTracking() }
                revealCursorAfterPointerMovement()
                isDragging = true
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: location,
                    clickCount: currentClickCount,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseDragged(mouseEvent))
                lastPanLocation = location
            }

        case .ended,
             .cancelled,
             .failed:
            guard directDoubleTapDragButtonDown else {
                isDragging = false
                return
            }

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: max(1, currentClickCount),
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            if gesture.state == .ended, !isDragging {
                commitPrimaryClick(
                    at: location,
                    timestamp: CACurrentMediaTime(),
                    clickCount: max(1, currentClickCount)
                )
            }
            directDoubleTapDragButtonDown = false
            isDragging = false

        default:
            break
        }
    }

    @objc
    func handleDirectTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopTouchScrollDeceleration()

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForLocalContact(location)

        let now = CACurrentMediaTime()
        let clickCount = nextSecondaryClickCount(at: location, timestamp: now)
        currentRightClickCount = clickCount

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: clickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
        commitSecondaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    @objc
    func handleDirectTwoFingerDrag(_ gesture: UIPanGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if swallowingDirectTwoFingerDragForCursorRecapture {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                swallowingDirectTwoFingerDragForCursorRecapture = false
            }
            return
        }
        if gesture.state == .began, requestCursorLockRecaptureIfNeeded() {
            swallowingDirectTwoFingerDragForCursorRecapture = true
            return
        }

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForLocalContact(location)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            stopTouchScrollDeceleration()
            resetPrimaryClickTracking()
            isDragging = true
            directTwoFingerDragButtonDown = true
            lastPanLocation = location

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))

        case .changed:
            guard directTwoFingerDragButtonDown else { return }
            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
                revealCursorAfterPointerMovement()
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseDragged(mouseEvent))
                lastPanLocation = location
            }

        case .ended,
             .cancelled,
             .failed:
            guard directTwoFingerDragButtonDown else {
                isDragging = false
                return
            }

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            directTwoFingerDragButtonDown = false
            isDragging = false

        default:
            break
        }
    }
}

#endif
