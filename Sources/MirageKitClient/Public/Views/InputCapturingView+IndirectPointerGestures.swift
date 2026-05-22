//
//  InputCapturingView+IndirectPointerGestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    @objc
    func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        requestResponderRecovery(.interaction)
        if swallowingLongPressForCursorRecapture {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                swallowingLongPressForCursorRecapture = false
            }
            return
        }

        if gesture.state == .began, requestCursorLockRecaptureIfNeeded() {
            swallowingLongPressForCursorRecapture = true
            return
        }

        let eventModifiers = modifiers(from: gesture)

        if gesture.numberOfTouches > 1 {
            if longPressButtonDown {
                let releaseLocation = pointerReleaseLocation()
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: releaseLocation,
                    clickCount: currentClickCount,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseUp(mouseEvent))
                longPressButtonDown = false
            }
            isDragging = false
            longPressCancelledForMultiTouch = true
            resetPrimaryClickTracking()
            return
        }

        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        updatePointerLocationForLocalContact(location)

        switch gesture.state {
        case .began:
            longPressCancelledForMultiTouch = false
            let now = CACurrentMediaTime()
            currentClickCount = nextPrimaryClickCount(at: location, timestamp: now)
            isDragging = false
            lastPanLocation = location

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
            longPressButtonDown = true

        case .changed:
            guard longPressButtonDown, !longPressCancelledForMultiTouch else { return }
            // Track all movement - no threshold, pixel-perfect dragging
            let distance = hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y)
            if distance > 0.0001 { // Any actual movement
                revealCursorAfterPointerMovement()
                if !isDragging { resetPrimaryClickTracking() }
                isDragging = true
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseDragged(mouseEvent))
                lastPanLocation = location
            }

        case .ended:
            guard longPressButtonDown else {
                isDragging = false
                longPressCancelledForMultiTouch = false
                return
            }
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            if !isDragging, !longPressCancelledForMultiTouch {
                commitPrimaryClick(at: location, timestamp: CACurrentMediaTime(), clickCount: currentClickCount)
            }
            isDragging = false
            longPressButtonDown = false
            longPressCancelledForMultiTouch = false

        case .cancelled,
             .failed:
            // Send mouseUp on cancel to avoid stuck mouse state
            if longPressButtonDown {
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: location,
                    clickCount: currentClickCount,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseUp(mouseEvent))
            }
            isDragging = false
            longPressButtonDown = false
            longPressCancelledForMultiTouch = false

        default:
            break
        }
    }

    @objc
    func handleRightClick(_ gesture: UITapGestureRecognizer) {
        requestResponderRecovery(.interaction)
        if requestCursorLockRecaptureIfNeeded() { return }

        let location = resolvedIndirectSecondaryClickLocation(gesture.location(in: self))
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
    func handleScroll(_ gesture: UIPanGestureRecognizer) {
        requestResponderRecovery(.interaction)
        let rawLocation = gesture.location(in: self)
        let translation = gesture.translation(in: self)
        let eventModifiers = modifiers(from: gesture)

        if gesture.state == .began {
            stopTouchScrollDeceleration()
            moveTrackpadCursorToDirectScrollStartIfNeeded(rawLocation, modifiers: eventModifiers)
        }

        let location = updatePointerLocationForScrollInteraction(rawLocation)

        // Reset translation to get incremental deltas
        gesture.setTranslation(.zero, in: self)

        let velocity = gesture.velocity(in: self)
        let shouldDecelerate = shouldDecelerateTouchScroll(for: velocity, state: gesture.state)

        let phase: MirageScrollPhase = {
            if shouldDecelerate, gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { return .none }
            return MirageScrollPhase(gestureState: gesture.state)
        }()

        if let scrollEvent = makeScrollEvent(
            deltaX: translation.x,
            deltaY: translation.y,
            location: location,
            phase: phase,
            modifiers: eventModifiers,
            isPrecise: true
        ) {
            onInputEvent?(.scrollWheel(scrollEvent))
        }

        if shouldDecelerate && (gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed) { startTouchScrollDeceleration(with: velocity, location: location) } else if gesture.state == .cancelled || gesture.state == .failed {
            stopTouchScrollDeceleration()
        }
    }

    @objc
    func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let sourceTimestamp = Date.timeIntervalSinceReferenceDate
        MirageInputLatencyTelemetry.shared.recordClientSource(
            eventClass: .pointer,
            streamID: streamID,
            source: "uiHover",
            timestamp: sourceTimestamp
        )
        requestResponderRecovery(.interaction)
        let hoverStylus = stylusHoverEvent(from: gesture)
        let hoverPressure: CGFloat = hoverStylus == nil ? 1.0 : 0.0
        let location = gesture.location(in: self)

        if cursorLockEnabled {
            guard !usesMouseInputDeltas else {
                MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                    eventClass: .pointer,
                    streamID: streamID,
                    source: "uiHover",
                    reason: "mouseDeltasActive",
                    sourceTimestamp: sourceTimestamp
                )
                return
            }
            switch gesture.state {
            case .began:
                lockedPointerLastHoverLocation = location
                noteLockedCursorLocalInput()
                setLockedCursorVisible(true)
                updateLockedCursorViewPosition()
                return
            case .changed:
                if lockedPointerButtonDown {
                    lockedPointerLastHoverLocation = nil
                    MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                        eventClass: .pointer,
                        streamID: streamID,
                        source: "uiHover",
                        reason: "lockedButtonDown",
                        sourceTimestamp: sourceTimestamp
                    )
                    return
                }
                if let lastLocation = lockedPointerLastHoverLocation {
                    if shouldIgnoreLockedPointerHoverJump(from: lastLocation, to: location) {
                        lockedPointerLastHoverLocation = nil
                        MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                            eventClass: .pointer,
                            streamID: streamID,
                            source: "uiHover",
                            reason: "lockedHoverJump",
                            sourceTimestamp: sourceTimestamp
                        )
                        return
                    }
                    let translation = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                    if translation != .zero {
                        scrollPhysicsView?.stopIndirectScrollDeceleration()
                        if hoverStylus == nil { revealCursorAfterPointerMovement() }
                        noteLockedPointerDragIfNeeded(for: translation)
                        applyLockedCursorDelta(translation)
                        let eventModifiers = modifiers(from: gesture)
                        if let hoverStylus {
                            sendPencilHoverBatch(
                                location: lockedCursorPosition,
                                stylus: hoverStylus,
                                modifiers: eventModifiers
                            )
                        } else {
                            sendLockedPointerMovementEvent(
                                location: lockedCursorPosition,
                                modifiers: eventModifiers,
                                pressure: hoverPressure
                            )
                        }
                    } else {
                        MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                            eventClass: .pointer,
                            streamID: streamID,
                            source: "uiHover",
                            reason: "zeroLockedTranslation",
                            sourceTimestamp: sourceTimestamp
                        )
                    }
                }
                lockedPointerLastHoverLocation = location
            default:
                sendPencilHoverExitIfNeeded()
                lockedPointerLastHoverLocation = nil
                setLockedCursorVisible(false)
            }
            return
        }
        if hoverStylus == nil, scrollPhysicsView?.isIndirectScrollActive == true {
            MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                eventClass: .pointer,
                streamID: streamID,
                source: "uiHover",
                reason: "indirectScrollActive",
                sourceTimestamp: sourceTimestamp
            )
            return
        }
        let normalized = normalizedLocation(location)
        let pointerMoved: Bool = if let lastCursorPosition {
            hypot(normalized.x - lastCursorPosition.x, normalized.y - lastCursorPosition.y) > 0.0001
        } else {
            false
        }

        switch gesture.state {
        case .began,
             .changed:
            if pointerMoved, hoverStylus == nil { revealCursorAfterPointerMovement() }
            if usesVirtualTrackpad {
                updateVirtualCursorPosition(normalized, updateVisibility: usesVisibleVirtualCursor)
            }

            // Track cursor position for scroll events
            lastCursorPosition = normalized
            updateLockedCursorViewVisibility()
            updateLockedCursorViewPosition()

            let shouldEmitHover = (hoverStylus != nil && gesture.state == .began) ||
                Self.shouldEmitPassiveHoverMove(
                    pointerMoved: pointerMoved,
                    isDragging: isDragging
                )

            if shouldEmitHover {
                let eventModifiers = modifiers(from: gesture)
                if let hoverStylus {
                    sendPencilHoverBatch(
                        location: normalized,
                        stylus: hoverStylus,
                        modifiers: eventModifiers
                    )
                } else {
                    let mouseEvent = MirageMouseEvent(
                        button: .left,
                        location: normalized,
                        modifiers: eventModifiers,
                        pressure: hoverPressure
                    )
                    MirageInputLatencyTelemetry.shared.recordClientSourceForward(
                        event: .mouseMoved(mouseEvent),
                        streamID: streamID,
                        source: "uiHover",
                        sourceTimestamp: sourceTimestamp
                    )
                    onInputEvent?(.mouseMoved(mouseEvent))
                }
            } else {
                MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                    eventClass: hoverStylus == nil ? .pointer : .touch,
                    streamID: streamID,
                    source: "uiHover",
                    reason: pointerMoved ? "dragging" : "noMovement",
                    sourceTimestamp: sourceTimestamp
                )
            }
        default:
            sendPencilHoverExitIfNeeded()
        }
    }
}

#endif
