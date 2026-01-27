//
//  InputCapturingView+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func setupGestureRecognizers() {
        // Tap gesture (works with touch and pointer click)
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(tapGesture)

        // Right-click gesture (secondary click with pointer)
        rightClickGesture = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickGesture.buttonMaskRequired = .secondary
        rightClickGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(rightClickGesture)

        // Pan gesture for dragging (touch and pointer)
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(panGesture)

        // Scroll gesture - ONLY for direct touch (2-finger pan on screen)
        // Trackpad scrolling uses ScrollPhysicsCapturingView for native momentum/bounce
        scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.allowedScrollTypesMask = []  // Disable trackpad scroll handling
        scrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        addGestureRecognizer(scrollGesture)

        // Hover gesture for pointer movement tracking
        hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hoverGesture)

        // Pinch gesture for direct touch zoom
        directPinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handleDirectPinch(_:)))
        directPinchGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directPinchGesture.delegate = self
        addGestureRecognizer(directPinchGesture)

        // Rotation gesture for direct touch
        directRotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleDirectRotation(_:)))
        directRotationGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        directRotationGesture.delegate = self
        addGestureRecognizer(directRotationGesture)

        // Allow simultaneous recognition
        tapGesture.delegate = self
        panGesture.delegate = self
        scrollGesture.delegate = self
    }

    // MARK: - Coordinate Helpers

    /// Normalize a point to 0-1 range relative to view bounds
    /// The gesture location is in self's coordinate space, so normalize against self.bounds
    /// This ensures correct mapping regardless of nested view hierarchy offsets
    func normalizedLocation(_ point: CGPoint) -> CGPoint {
        // Normalize directly against our bounds - the view receiving the gesture
        // Scale factors cancel out: (point * scale) / (bounds * scale) = point / bounds
        guard bounds.width > 0 && bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)  // Default to center if bounds not ready
        }

        var normalized = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )

        if dockSnapEnabled {
            // Snap cursor to bottom edge when in dock trigger zone (bottom 1%)
            // This allows users to easily open the iPad dock without precise edge targeting
            if normalized.y >= 0.99 {
                normalized.y = 1.0
            }
        }

        return normalized
    }

    /// Get combined modifiers from a gesture (at event time) and keyboard state
    /// This is the proper way to get modifiers for pointer events - read from gesture directly
    func modifiers(from gesture: UIGestureRecognizer) -> MirageModifierFlags {
        resyncModifierState(from: gesture.modifierFlags)
        let gestureModifiers = MirageModifierFlags(uiKeyModifierFlags: gesture.modifierFlags)
        return gestureModifiers.union(keyboardModifiers)
    }

    // MARK: - Gesture Handlers

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        let now = CACurrentMediaTime()

        // Detect multi-click: check if this tap is close enough in time and space to the previous one
        let timeSinceLastTap = now - lastTapTime
        let distance = hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y)

        if timeSinceLastTap < Self.multiClickTimeThreshold && distance < Self.multiClickDistanceThreshold {
            // Increment click count for multi-click (double-click, triple-click, etc.)
            currentClickCount += 1
        } else {
            // Reset to single click
            currentClickCount = 1
        }

        // Update tracking state for next tap
        lastTapTime = now
        lastTapLocation = location

        // Debug logging for coordinate tracking
        MirageLogger.client("TAP: raw=(\(Int(rawLocation.x)), \(Int(rawLocation.y))), bounds=(\(Int(bounds.width))x\(Int(bounds.height))), normalized=(\(String(format: "%.3f", location.x)), \(String(format: "%.3f", location.y))), clickCount=\(currentClickCount)")

        // Read modifiers directly from gesture at event time
        let eventModifiers = modifiers(from: gesture)

        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: currentClickCount,
            modifiers: eventModifiers
        )

        // Send mouse down then mouse up for a click
        onInputEvent?(.mouseDown(mouseEvent))
        onInputEvent?(.mouseUp(mouseEvent))
    }

    @objc func handleRightClick(_ gesture: UITapGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))
        let now = CACurrentMediaTime()

        // Detect multi-click for right button
        let timeSinceLastTap = now - lastRightTapTime
        let distance = hypot(location.x - lastRightTapLocation.x, location.y - lastRightTapLocation.y)

        if timeSinceLastTap < Self.multiClickTimeThreshold && distance < Self.multiClickDistanceThreshold {
            currentRightClickCount += 1
        } else {
            currentRightClickCount = 1
        }

        lastRightTapTime = now
        lastRightTapLocation = location

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: currentRightClickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            isDragging = true
            lastPanLocation = location
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseDown(mouseEvent))

        case .changed:
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseDragged(mouseEvent))
            lastPanLocation = location

        case .ended, .cancelled:
            isDragging = false
            let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
            onInputEvent?(.mouseUp(mouseEvent))

        default:
            break
        }
    }

    @objc func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        // For touch scrolling, use the gesture location (center of two fingers)
        let location = normalizedLocation(gesture.location(in: self))

        // Reset translation to get incremental deltas
        gesture.setTranslation(.zero, in: self)

        let eventModifiers = modifiers(from: gesture)
        let scrollEvent = MirageScrollEvent(
            deltaX: translation.x,
            deltaY: translation.y,
            location: location,
            phase: MirageScrollPhase(gestureState: gesture.state),
            modifiers: eventModifiers,
            isPrecise: true  // Trackpad/touch scrolling is precise
        )

        onInputEvent?(.scrollWheel(scrollEvent))
    }

    /// Detect large, axis-dominant trackpad scrolls and map them to arrow keys.
    /// This provides a fallback for swipe-style navigation in apps that rely on
    /// gesture semantics instead of scroll deltas.
    func handleTrackpadSwipeIfNeeded(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: MirageScrollPhase,
        momentumPhase: MirageScrollPhase
    ) -> Bool {
        let gestureBegan = phase == .began || momentumPhase == .began
        if gestureBegan {
            trackpadSwipeAccumX = 0
            trackpadSwipeAccumY = 0
            trackpadSwipeArrowSent = false
            return false
        }

        let gestureEnded = phase == .ended || phase == .cancelled ||
            momentumPhase == .ended || momentumPhase == .cancelled
        if gestureEnded {
            trackpadSwipeAccumX = 0
            trackpadSwipeAccumY = 0
            trackpadSwipeArrowSent = false
            return false
        }

        // Only consider swipe detection during direct finger tracking, not momentum.
        guard phase == .changed, momentumPhase == .none else { return false }

        trackpadSwipeAccumX += deltaX
        trackpadSwipeAccumY += deltaY

        guard !trackpadSwipeArrowSent else { return false }

        let absX = abs(trackpadSwipeAccumX)
        let absY = abs(trackpadSwipeAccumY)

        if absX >= trackpadSwipeDistanceThreshold && absX > absY * trackpadSwipeAxisRatioThreshold {
            sendArrowKey(trackpadSwipeAccumX > 0 ? 0x7C : 0x7B)
            trackpadSwipeArrowSent = true
            return true
        }

        if absY >= trackpadSwipeDistanceThreshold && absY > absX * trackpadSwipeAxisRatioThreshold {
            sendArrowKey(trackpadSwipeAccumY > 0 ? 0x7E : 0x7D)
            trackpadSwipeArrowSent = true
            return true
        }

        return false
    }

    @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let location = normalizedLocation(gesture.location(in: self))

        switch gesture.state {
        case .began, .changed:
            // Track cursor position for scroll events
            lastCursorPosition = location

            // Only send mouse moved if not dragging (pan gesture handles that)
            if !isDragging {
                let eventModifiers = modifiers(from: gesture)
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseMoved(mouseEvent))
            }
        default:
            break
        }
    }

    // MARK: - Direct Touch Gesture Handlers

    @objc func handleDirectPinch(_ gesture: UIPinchGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastDirectPinchScale = 1.0
            let event = MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))

        case .changed:
            let magnification = gesture.scale - lastDirectPinchScale
            lastDirectPinchScale = gesture.scale
            let event = MirageMagnifyEvent(magnification: magnification, phase: phase)
            onInputEvent?(.magnify(event))

        case .ended, .cancelled:
            let event = MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))
            lastDirectPinchScale = 1.0

        default:
            break
        }
    }

    @objc func handleDirectRotation(_ gesture: UIRotationGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastDirectRotationAngle = 0
            let event = MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))

        case .changed:
            // Convert radians to degrees for the delta
            let rotationDelta = (gesture.rotation - lastDirectRotationAngle) * (180.0 / .pi)
            lastDirectRotationAngle = gesture.rotation
            let event = MirageRotateEvent(rotation: rotationDelta, phase: phase)
            onInputEvent?(.rotate(event))

        case .ended, .cancelled:
            let event = MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))
            lastDirectRotationAngle = 0

        default:
            break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InputCapturingView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow hover to work with other gestures
        if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
            return true
        }

        // Allow pinch and rotation to work simultaneously (map-style interaction)
        if (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) ||
           (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }

        return false
    }
}

// MARK: - Trackpad Swipe Helpers

private extension InputCapturingView {
    func sendArrowKey(_ keyCode: UInt16) {
        let modifiers = keyboardModifiers
        let keyEvent = MirageKeyEvent(keyCode: keyCode, modifiers: modifiers)
        onInputEvent?(.keyDown(keyEvent))
        onInputEvent?(.keyUp(keyEvent))
    }
}
#endif
