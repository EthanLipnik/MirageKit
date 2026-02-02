//
//  InputCapturingView+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    private static let dockSnapThreshold: CGFloat = 0.98

    func setupGestureRecognizers() {
        // Long press gesture for immediate click detection
        // minimumPressDuration=0 fires immediately on touch down
        // allowableMovement is ignored after recognition, so .changed fires for all movement
        // This replaces both tap and pan gestures for unified mouse handling
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0
        longPressGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        // Right-click gesture (secondary click with pointer)
        rightClickGesture = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickGesture.buttonMaskRequired = .secondary
        rightClickGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(rightClickGesture)

        // Scroll gesture - ONLY for direct touch (2-finger pan on screen)
        // Trackpad scrolling uses ScrollPhysicsCapturingView for native momentum/bounce
        scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.allowedScrollTypesMask = [] // Disable trackpad scroll handling
        scrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        scrollGesture.delegate = self
        addGestureRecognizer(scrollGesture)

        // Hover gesture for pointer movement tracking
        hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hoverGesture)

        // Locked pointer gestures (indirect pointer only)
        lockedPointerPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLockedPointerPan(_:)))
        lockedPointerPanGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
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
        lockedPointerPressGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
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

    /// Normalize a point to 0-1 range relative to view bounds
    /// The gesture location is in self's coordinate space, so normalize against self.bounds
    /// This ensures correct mapping regardless of nested view hierarchy offsets
    func normalizedLocation(_ point: CGPoint) -> CGPoint {
        // Normalize directly against our bounds - the view receiving the gesture
        // Scale factors cancel out: (point * scale) / (bounds * scale) = point / bounds
        // Default to center if bounds not ready
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }

        var normalized = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )
        return applyDockSnap(to: normalized)
    }

    func applyDockSnap(to normalized: CGPoint) -> CGPoint {
        guard dockSnapEnabled else { return normalized }

        var snapped = normalized
        // Snap cursor to bottom edge when in dock trigger zone (bottom 2%)
        // This allows users to easily open the iPad dock without precise edge targeting
        if snapped.y >= Self.dockSnapThreshold { snapped.y = 1.0 }

        return snapped
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

    @objc
    func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        let eventModifiers = modifiers(from: gesture)

        if cursorLockEnabled {
            lockedCursorPosition = location
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            updateLockedCursorViewPosition()
        }

        if usesVirtualTrackpad {
            setVirtualCursorVisible(false)
            updateVirtualCursorPosition(location, updateVisibility: false)
        }

        switch gesture.state {
        case .began:
            // Detect multi-click timing
            let now = CACurrentMediaTime()
            let timeSinceLastTap = now - lastTapTime
            let distance = hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y)

            if timeSinceLastTap < Self.multiClickTimeThreshold, distance < Self.multiClickDistanceThreshold { currentClickCount += 1 } else {
                currentClickCount = 1
            }

            lastTapTime = now
            lastTapLocation = location
            isDragging = false
            lastPanLocation = location

            MirageLogger
                .client(
                    "PRESS: normalized=(\(String(format: "%.3f", location.x)), \(String(format: "%.3f", location.y))), clickCount=\(currentClickCount)"
                )

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))

        case .changed:
            // Track all movement - no threshold, pixel-perfect dragging
            let distance = hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y)
            if distance > 0.0001 { // Any actual movement
                isDragging = true
                let mouseEvent = MirageMouseEvent(button: .left, location: location, modifiers: eventModifiers)
                onInputEvent?(.mouseDragged(mouseEvent))
                lastPanLocation = location
            }

        case .ended:
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            isDragging = false

        case .cancelled:
            // Send mouseUp on cancel to avoid stuck mouse state
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            isDragging = false

        default:
            break
        }
    }

    @objc
    func handleRightClick(_ gesture: UITapGestureRecognizer) {
        let location: CGPoint
        if cursorLockEnabled {
            setLockedCursorVisible(true)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(gesture.location(in: self))
        }
        let now = CACurrentMediaTime()

        // Detect multi-click for right button
        let timeSinceLastTap = now - lastRightTapTime
        let distance = hypot(location.x - lastRightTapLocation.x, location.y - lastRightTapLocation.y)

        if timeSinceLastTap < Self.multiClickTimeThreshold, distance < Self.multiClickDistanceThreshold { currentRightClickCount += 1 } else {
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

    @objc
    func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        let location: CGPoint = if usesVirtualTrackpad {
            virtualCursorPosition
        } else {
            // For touch scrolling, use the gesture location (center of two fingers)
            normalizedLocation(gesture.location(in: self))
        }

        if gesture.state == .began { stopTouchScrollDeceleration() }

        // Reset translation to get incremental deltas
        gesture.setTranslation(.zero, in: self)

        let velocity = gesture.velocity(in: self)
        let shouldDecelerate = shouldDecelerateTouchScroll(for: velocity, state: gesture.state)

        let eventModifiers = modifiers(from: gesture)
        let phase: MirageScrollPhase = {
            if shouldDecelerate, gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { return .none }
            return MirageScrollPhase(gestureState: gesture.state)
        }()

        let scrollEvent = MirageScrollEvent(
            deltaX: translation.x,
            deltaY: translation.y,
            location: location,
            phase: phase,
            modifiers: eventModifiers,
            isPrecise: true // Trackpad/touch scrolling is precise
        )

        if translation != .zero || phase != .none { onInputEvent?(.scrollWheel(scrollEvent)) }

        if shouldDecelerate && (gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed) { startTouchScrollDeceleration(with: velocity, location: location) } else if gesture.state == .cancelled || gesture.state == .failed {
            stopTouchScrollDeceleration()
        }
    }

    @objc
    func handleHover(_ gesture: UIHoverGestureRecognizer) {
        if cursorLockEnabled {
            guard !usesMouseInputDeltas else { return }
            let location = gesture.location(in: self)
            switch gesture.state {
            case .began:
                lockedPointerLastHoverLocation = location
                noteLockedCursorLocalInput()
                setLockedCursorVisible(true)
                updateLockedCursorViewPosition()
                return
            case .changed:
                if lockedPointerButtonDown {
                    lockedPointerLastHoverLocation = location
                    return
                }
                if let lastLocation = lockedPointerLastHoverLocation {
                    let translation = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                    if translation != .zero {
                        applyLockedCursorDelta(translation)
                        let eventModifiers = modifiers(from: gesture)
                        let mouseEvent = MirageMouseEvent(
                            button: .left,
                            location: lockedCursorPosition,
                            modifiers: eventModifiers
                        )
                        onInputEvent?(.mouseMoved(mouseEvent))
                    }
                }
                lockedPointerLastHoverLocation = location
            default:
                lockedPointerLastHoverLocation = nil
            }
            return
        }
        let location = normalizedLocation(gesture.location(in: self))

        switch gesture.state {
        case .began,
             .changed:
            if usesVirtualTrackpad {
                setVirtualCursorVisible(false)
                updateVirtualCursorPosition(location, updateVisibility: false)
            }

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

    // MARK: - Locked Pointer Handlers

    @objc
    func handleLockedPointerPan(_ gesture: UIPanGestureRecognizer) {
        guard cursorLockEnabled else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        switch gesture.state {
        case .began,
             .changed:
            applyLockedCursorDelta(translation)
            let eventModifiers = modifiers(from: gesture)
            let mouseEvent = MirageMouseEvent(button: .left, location: lockedCursorPosition, modifiers: eventModifiers)
            if lockedPointerButtonDown { onInputEvent?(.mouseDragged(mouseEvent)) } else {
                onInputEvent?(.mouseMoved(mouseEvent))
            }
        default:
            break
        }
    }

    @objc
    func handleLockedPointerPress(_ gesture: UILongPressGestureRecognizer) {
        guard cursorLockEnabled else { return }
        setLockedCursorVisible(true)
        let location = lockedCursorPosition
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            noteLockedCursorLocalInput()
            let now = CACurrentMediaTime()
            let timeSinceLastTap = now - lastTapTime
            let distance = hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y)

            if timeSinceLastTap < Self.multiClickTimeThreshold, distance < Self.multiClickDistanceThreshold { currentClickCount += 1 } else {
                currentClickCount = 1
            }

            lastTapTime = now
            lastTapLocation = location
            lockedPointerButtonDown = true

            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
        case .ended, .cancelled:
            noteLockedCursorLocalInput()
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: location,
                clickCount: currentClickCount,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            lockedPointerButtonDown = false
        default:
            break
        }
    }

    // MARK: - Virtual Cursor Handlers

    @objc
    func handleVirtualCursorPan(_ gesture: UIPanGestureRecognizer) {
        guard usesVirtualTrackpad else { return }
        setVirtualCursorVisible(true)
        if gesture.state == .began { stopVirtualCursorDeceleration() }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        switch gesture.state {
        case .began,
             .changed:
            moveVirtualCursor(by: translation)
            let eventModifiers = modifiers(from: gesture)
            let mouseEvent = MirageMouseEvent(button: .left, location: virtualCursorPosition, modifiers: eventModifiers)
            if virtualDragActive { onInputEvent?(.mouseDragged(mouseEvent)) } else {
                onInputEvent?(.mouseMoved(mouseEvent))
            }
        case .ended:
            if !virtualDragActive { startVirtualCursorDeceleration(with: gesture.velocity(in: self)) }
        default:
            break
        }
    }

    @objc
    func handleVirtualCursorLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard usesVirtualTrackpad else { return }
        setVirtualCursorVisible(true)
        if gesture.state == .began { stopVirtualCursorDeceleration() }
        let location = normalizedLocation(gesture.location(in: self))
        updateVirtualCursorPosition(location, updateVisibility: false)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            virtualDragActive = true
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: virtualCursorPosition,
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
        case .cancelled,
             .ended:
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: virtualCursorPosition,
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseUp(mouseEvent))
            virtualDragActive = false
        default:
            break
        }
    }

    @objc
    func handleVirtualCursorTap(_ gesture: UITapGestureRecognizer) {
        guard usesVirtualTrackpad else { return }
        stopVirtualCursorDeceleration()
        setVirtualCursorVisible(true)

        let now = CACurrentMediaTime()
        let timeSinceLastTap = now - lastTapTime
        let distance = hypot(
            virtualCursorPosition.x - lastTapLocation.x,
            virtualCursorPosition.y - lastTapLocation.y
        )

        if timeSinceLastTap < Self.multiClickTimeThreshold, distance < Self.multiClickDistanceThreshold { currentClickCount += 1 } else {
            currentClickCount = 1
        }

        lastTapTime = now
        lastTapLocation = virtualCursorPosition

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: virtualCursorPosition,
            clickCount: currentClickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.mouseDown(mouseEvent))
        onInputEvent?(.mouseUp(mouseEvent))
    }

    @objc
    func handleVirtualCursorRightTap(_ gesture: UITapGestureRecognizer) {
        guard usesVirtualTrackpad else { return }
        stopVirtualCursorDeceleration()
        setVirtualCursorVisible(true)

        let now = CACurrentMediaTime()
        let timeSinceLastTap = now - lastRightTapTime
        let distance = hypot(
            virtualCursorPosition.x - lastRightTapLocation.x,
            virtualCursorPosition.y - lastRightTapLocation.y
        )

        if timeSinceLastTap < Self.multiClickTimeThreshold, distance < Self.multiClickDistanceThreshold { currentRightClickCount += 1 } else {
            currentRightClickCount = 1
        }

        lastRightTapTime = now
        lastRightTapLocation = virtualCursorPosition

        let eventModifiers = modifiers(from: gesture)
        let mouseEvent = MirageMouseEvent(
            button: .right,
            location: virtualCursorPosition,
            clickCount: currentRightClickCount,
            modifiers: eventModifiers
        )

        onInputEvent?(.rightMouseDown(mouseEvent))
        onInputEvent?(.rightMouseUp(mouseEvent))
    }

    // MARK: - Direct Touch Gesture Handlers

    @objc
    func handleDirectPinch(_ gesture: UIPinchGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)
        refreshModifiersForInput()

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

        case .cancelled,
             .ended:
            let event = MirageMagnifyEvent(magnification: 0, phase: phase)
            onInputEvent?(.magnify(event))
            lastDirectPinchScale = 1.0

        default:
            break
        }
    }

    @objc
    func handleDirectRotation(_ gesture: UIRotationGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)
        refreshModifiersForInput()

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

        case .cancelled,
             .ended:
            let event = MirageRotateEvent(rotation: 0, phase: phase)
            onInputEvent?(.rotate(event))
            lastDirectRotationAngle = 0

        default:
            break
        }
    }

    func moveVirtualCursor(by translation: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard translation != .zero else { return }

        var updated = virtualCursorPosition
        updated.x += translation.x / bounds.width
        updated.y += translation.y / bounds.height
        updateVirtualCursorPosition(updated, updateVisibility: true)
    }

    func updateVirtualCursorPosition(_ position: CGPoint, updateVisibility: Bool) {
        var clamped = CGPoint(
            x: min(max(position.x, 0.0), 1.0),
            y: min(max(position.y, 0.0), 1.0)
        )
        clamped = applyDockSnap(to: clamped)

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
        displayLink.add(to: .main, forMode: .common)
        touchScrollDecelerationLink = displayLink
    }

    func stopTouchScrollDeceleration() {
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
            let scrollEvent = MirageScrollEvent(
                deltaX: translation.x,
                deltaY: translation.y,
                location: touchScrollDecelerationLocation,
                phase: .none,
                momentumPhase: .changed,
                modifiers: keyboardModifiers,
                isPrecise: true
            )
            onInputEvent?(.scrollWheel(scrollEvent))
        }

        let decay = CGFloat(pow(Double(decelerationRate), dt * 1000))
        touchScrollDecelerationVelocity.x *= decay
        touchScrollDecelerationVelocity.y *= decay

        if hypot(touchScrollDecelerationVelocity.x, touchScrollDecelerationVelocity.y) < 8 {
            stopTouchScrollDeceleration()
            let endEvent = MirageScrollEvent(
                deltaX: 0,
                deltaY: 0,
                location: touchScrollDecelerationLocation,
                phase: .none,
                momentumPhase: .ended,
                modifiers: keyboardModifiers,
                isPrecise: true
            )
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
            moveVirtualCursor(by: translation)
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: virtualCursorPosition,
                modifiers: keyboardModifiers
            )
            onInputEvent?(.mouseMoved(mouseEvent))
        }

        let decay = CGFloat(pow(Double(decelerationRate), dt * 60))
        virtualCursorVelocity.x *= decay
        virtualCursorVelocity.y *= decay

        if hypot(virtualCursorVelocity.x, virtualCursorVelocity.y) < 5 { stopVirtualCursorDeceleration() }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InputCapturingView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    )
    -> Bool {
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

        if (gestureRecognizer == lockedPointerPanGesture && otherGestureRecognizer == lockedPointerPressGesture) ||
            (gestureRecognizer == lockedPointerPressGesture && otherGestureRecognizer == lockedPointerPanGesture) {
            return true
        }

        return false
    }
}
#endif
