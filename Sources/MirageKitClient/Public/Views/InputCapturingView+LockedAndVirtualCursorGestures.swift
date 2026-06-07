//
//  InputCapturingView+LockedAndVirtualCursorGestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    // MARK: - Locked Pointer Handlers

    @objc
    func handleLockedPointerPan(_ gesture: UIPanGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        switch gesture.state {
        case .began,
             .changed:
            if translation != .zero {
                scrollPhysicsView?.stopIndirectScrollDeceleration()
                revealCursorAfterPointerMovement()
            }
            noteLockedPointerDragIfNeeded(for: translation)
            applyLockedCursorDelta(translation)
            let eventModifiers = modifiers(from: gesture)
            sendLockedPointerMovementEvent(location: lockedCursorPosition, modifiers: eventModifiers)
        default:
            break
        }
    }

    @objc
    func handleLockedPointerPress(_ gesture: UILongPressGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard cursorLockEnabled else { return }
        setLockedCursorVisible(true)
        let location = lockedCursorActionPosition()
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            noteLockedCursorLocalInput()
            let now = CACurrentMediaTime()
            currentClickCount = nextPrimaryClickCount(at: location, timestamp: now)
            lockedPointerButtonDown = true
            lockedPointerDraggedSinceDown = false
            lockedPointerLastHoverLocation = nil

            let mouseEvent = MirageInput.MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
        case .ended, .cancelled:
            noteLockedCursorLocalInput()
            let mouseEvent = MirageInput.MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            if gesture.state == .ended, !lockedPointerDraggedSinceDown {
                commitPrimaryClick(at: location, timestamp: CACurrentMediaTime(), clickCount: currentClickCount)
            }
            lockedPointerButtonDown = false
            lockedPointerDraggedSinceDown = false
            lockedPointerLastHoverLocation = nil
        default:
            break
        }
    }

    // MARK: - Virtual Cursor Handlers

    @objc
    func handleVirtualCursorPan(_ gesture: UIPanGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard usesVirtualTrackpad else { return }
        setTrackpadCursorVisible(true)
        if gesture.state == .began { stopVirtualCursorDeceleration() }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        switch gesture.state {
        case .began,
             .changed:
            moveTrackpadCursor(by: translation)
            let eventModifiers = modifiers(from: gesture)
            sendTrackpadMovementEvent(modifiers: eventModifiers)
        case .ended:
            if !virtualPointerButtonDown { startVirtualCursorDeceleration(with: gesture.velocity(in: self)) }
        case .cancelled,
             .failed:
            stopVirtualCursorDeceleration()
        default:
            break
        }
    }

    @objc
    func handleVirtualCursorLongPress(_ gesture: UILongPressGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard usesVirtualTrackpad else { return }
        if swallowingVirtualCursorLongPressForCursorRecapture {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                swallowingVirtualCursorLongPressForCursorRecapture = false
            }
            return
        }
        if gesture.state == .began, requestCursorLockRecaptureIfNeeded() {
            swallowingVirtualCursorLongPressForCursorRecapture = true
            return
        }
        setTrackpadCursorVisible(true)
        if gesture.state == .began { stopVirtualCursorDeceleration() }
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            guard !virtualPointerButtonDown else { return }
            virtualPointerButtonDown = true
            virtualDragActive = true
            resetPrimaryClickTracking()
            let location = trackpadCursorActionPosition()
            let mouseEvent = MirageInput.MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: 1,
                modifiers: eventModifiers
            )
            logVirtualTrackpadPointerEvent("long_press_down", location: location, clickCount: 1)
            onInputEvent?(.mouseDown(mouseEvent))
        case .cancelled,
             .ended,
             .failed:
            guard virtualPointerButtonDown else { return }
            let location = trackpadCursorActionPosition()
            let mouseEvent = MirageInput.MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: 1,
                modifiers: eventModifiers
            )
            logVirtualTrackpadPointerEvent(
                gesture.state == .ended ? "long_press_up" : "long_press_cancel",
                location: location,
                clickCount: 1
            )
            onInputEvent?(.mouseUp(mouseEvent))
            virtualPointerButtonDown = false
            virtualDragActive = false
        default:
            break
        }
    }

    @objc
    func handleVirtualCursorTap(_ gesture: UITapGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard usesVirtualTrackpad else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopVirtualCursorDeceleration()
        setTrackpadCursorVisible(true)
        let location = trackpadCursorActionPosition()

        let now = CACurrentMediaTime()
        let clickCount = nextPrimaryClickCount(at: location, timestamp: now)
        currentClickCount = clickCount

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: clickCount,
            modifiers: eventModifiers
        )

        logVirtualTrackpadPointerEvent("tap_down", location: location, clickCount: clickCount)
        onInputEvent?(.mouseDown(mouseEvent))
        logVirtualTrackpadPointerEvent("tap_up", location: location, clickCount: clickCount)
        onInputEvent?(.mouseUp(mouseEvent))
        commitPrimaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    @objc
    func handleVirtualCursorRightTap(_ gesture: UITapGestureRecognizer) {
        requestResponderRecovery(.interaction)
        guard usesVirtualTrackpad else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopVirtualCursorDeceleration()
        setTrackpadCursorVisible(true)
        let location = trackpadCursorActionPosition()

        let now = CACurrentMediaTime()
        let clickCount = nextSecondaryClickCount(at: location, timestamp: now)
        currentRightClickCount = clickCount

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: clickCount,
            modifiers: eventModifiers
        )

        logVirtualTrackpadPointerEvent("right_tap_down", location: location, clickCount: clickCount)
        onInputEvent?(.rightMouseDown(mouseEvent))
        logVirtualTrackpadPointerEvent("right_tap_up", location: location, clickCount: clickCount)
        onInputEvent?(.rightMouseUp(mouseEvent))
        commitSecondaryClick(at: location, timestamp: now, clickCount: clickCount)
    }

    // MARK: - Direct Touch Gesture Handlers

    @objc
    func handleDirectPinch(_ gesture: UIPinchGestureRecognizer) {
        requestResponderRecovery(.interaction)
        let phase = MirageInput.MirageScrollPhase(gestureState: gesture.state)
        syncModifiersForInput()

        switch gesture.state {
        case .began:
            lastDirectPinchScale = 1.0
            let event = MirageInput.MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))

        case .changed:
            let magnification = gesture.scale - lastDirectPinchScale
            lastDirectPinchScale = gesture.scale
            let event = MirageInput.MirageMagnifyEvent(magnification: magnification, phase: phase)
            onInputEvent?(.magnify(event))

        case .cancelled,
             .ended:
            let event = MirageInput.MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))
            lastDirectPinchScale = 1.0

        default:
            break
        }
    }

    @objc
    func handleDirectRotation(_ gesture: UIRotationGestureRecognizer) {
        requestResponderRecovery(.interaction)
        let phase = MirageInput.MirageScrollPhase(gestureState: gesture.state)
        syncModifiersForInput()

        switch gesture.state {
        case .began:
            lastDirectRotationAngle = 0
            let event = MirageInput.MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))

        case .changed:
            // Convert radians to degrees for the delta
            let rotationDelta = (gesture.rotation - lastDirectRotationAngle) * (180.0 / .pi)
            lastDirectRotationAngle = gesture.rotation
            let event = MirageInput.MirageRotateEvent(rotation: rotationDelta, phase: phase)
            onInputEvent?(.rotate(event))

        case .cancelled,
             .ended:
            let event = MirageInput.MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))
            lastDirectRotationAngle = 0

        default:
            break
        }
    }

    func moveVirtualCursor(by translation: CGPoint) {
        let contentRect = resolvedPresentationContentRect()
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        guard translation != .zero else { return }

        revealCursorAfterCursorDrivenMovement()
        var updated = virtualCursorPosition
        updated.x += translation.x / contentRect.width
        updated.y += translation.y / contentRect.height
        updateVirtualCursorPosition(updated, updateVisibility: true)
    }

    func updateVirtualCursorPosition(_ position: CGPoint, updateVisibility: Bool) {
        var clamped = CGPoint(
            x: min(max(position.x, 0.0), 1.0),
            y: min(max(position.y, 0.0), 1.0)
        )

        virtualCursorPosition = clamped
        lastCursorPosition = clamped
        if updateVisibility { setVirtualCursorVisible(true) }
        updateVirtualCursorViewPosition()
    }

    func startVirtualCursorDeceleration(with velocity: CGPoint) {
        stopVirtualCursorDeceleration()
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 5 else { return }
        virtualCursorVelocity = velocity

        let displayLink = CADisplayLink(target: self, selector: #selector(handleVirtualCursorDeceleration(_:)))
        configureInteractionDisplayLink(displayLink)
        displayLink.add(to: .main, forMode: .common)
        virtualCursorDecelerationLink = displayLink
    }

    func stopVirtualCursorDeceleration() {
        virtualCursorDecelerationLink?.invalidate()
        virtualCursorDecelerationLink = nil
        virtualCursorVelocity = .zero
    }

    func shouldDecelerateTouchScroll(for velocity: CGPoint, state: UIGestureRecognizer.State) -> Bool {
        guard state == .ended || state == .cancelled || state == .failed else { return false }
        let speed = hypot(velocity.x, velocity.y)
        return speed > 30
    }

    func startTouchScrollDeceleration(with velocity: CGPoint, location: CGPoint) {
        guard shouldDecelerateTouchScroll(for: velocity, state: .ended) else { return }
        stopTouchScrollDeceleration()
        touchScrollDecelerationVelocity = velocity
        touchScrollDecelerationLocation = location

        let displayLink = CADisplayLink(target: self, selector: #selector(handleTouchScrollDeceleration(_:)))
        configureInteractionDisplayLink(displayLink)
        displayLink.add(to: .main, forMode: .common)
        touchScrollDecelerationLink = displayLink
    }

    func stopTouchScrollDeceleration() {
        scrollPhysicsView?.cancelDirectTouchScrolling()
        directTouchScrollAnchorLocation = nil
        directTouchScrollMomentumActive = false
        touchScrollDecelerationLink?.invalidate()
        touchScrollDecelerationLink = nil
        touchScrollDecelerationVelocity = .zero
    }

    @objc
    func handleTouchScrollDeceleration(_ displayLink: CADisplayLink) {
        let dt = displayLink.targetTimestamp - displayLink.timestamp
        let decelerationRate = UIScrollView.DecelerationRate.normal.rawValue

        let translation = CGPoint(
            x: touchScrollDecelerationVelocity.x * dt,
            y: touchScrollDecelerationVelocity.y * dt
        )

        if translation != .zero {
            guard let scrollEvent = makeScrollEvent(
                deltaX: translation.x,
                deltaY: translation.y,
                location: touchScrollDecelerationLocation,
                phase: .none,
                momentumPhase: .changed,
                modifiers: keyboardModifiers,
                isPrecise: true,
                preservePhaseMetadata: true
            ) else { return }
            onInputEvent?(.scrollWheel(scrollEvent))
        }

        let decay = CGFloat(pow(Double(decelerationRate), dt * 1000))
        touchScrollDecelerationVelocity.x *= decay
        touchScrollDecelerationVelocity.y *= decay

        if hypot(touchScrollDecelerationVelocity.x, touchScrollDecelerationVelocity.y) < 8 {
            stopTouchScrollDeceleration()
            guard let endEvent = makeScrollEvent(
                deltaX: 0,
                deltaY: 0,
                location: touchScrollDecelerationLocation,
                phase: .none,
                momentumPhase: .ended,
                modifiers: keyboardModifiers,
                isPrecise: true,
                preservePhaseMetadata: true
            ) else { return }
            onInputEvent?(.scrollWheel(endEvent))
        }
    }

    @objc
    func handleVirtualCursorDeceleration(_ displayLink: CADisplayLink) {
        guard !virtualDragActive else {
            stopVirtualCursorDeceleration()
            return
        }
        let dt = displayLink.targetTimestamp - displayLink.timestamp
        let decelerationRate: CGFloat = 0.90

        let translation = CGPoint(
            x: virtualCursorVelocity.x * dt,
            y: virtualCursorVelocity.y * dt
        )
        if translation != .zero {
            moveTrackpadCursor(by: translation)
            sendTrackpadMovementEvent(modifiers: keyboardModifiers)
        }

        let decay = CGFloat(pow(Double(decelerationRate), dt * 60))
        virtualCursorVelocity.x *= decay
        virtualCursorVelocity.y *= decay

        if hypot(virtualCursorVelocity.x, virtualCursorVelocity.y) < 5 { stopVirtualCursorDeceleration() }
    }
}

#endif
