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
    func setupGestureRecognizers() {
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

        // Legacy direct-touch scrolling for virtual trackpad mode.
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

    /// Normalize a point to 0-1 range relative to view bounds
    /// The gesture location is in self's coordinate space, so normalize against self.bounds
    /// This ensures correct mapping regardless of nested view hierarchy offsets
    func normalizedLocation(_ point: CGPoint) -> CGPoint {
        // Normalize directly against our bounds - the view receiving the gesture
        // Scale factors cancel out: (point * scale) / (bounds * scale) = point / bounds
        // Default to center if bounds not ready
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }

        let normalized = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )
        return normalized
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

    func updatePointerLocationForDirectInteraction(_ location: CGPoint) {
        updatePointerLocationForLocalContact(location)
    }

    @discardableResult
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
            updateTrackpadCursorPosition(location, updateVisibility: true)
            return trackpadCursorPosition()
        }

        lastCursorPosition = location
        return location
    }

    @objc
    func handleDirectTap(_ gesture: UITapGestureRecognizer) {
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopTouchScrollDeceleration()

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForDirectInteraction(location)

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

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForDirectInteraction(location)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            stopTouchScrollDeceleration()
            resetPrimaryClickTracking()
            isDragging = false
            directLongPressButtonDown = false
            lastPanLocation = location

        case .changed:
            if !directLongPressButtonDown {
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: location,
                    clickCount: 1,
                    modifiers: eventModifiers
                )
                onInputEvent?(.mouseDown(mouseEvent))
                directLongPressButtonDown = true
            }
            if hypot(location.x - lastPanLocation.x, location.y - lastPanLocation.y) > 0.0001 {
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
    func handleDirectTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard cursorLockEnabled || directTouchInputMode == .normal else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopTouchScrollDeceleration()

        let location = normalizedLocation(gesture.location(in: self))
        updatePointerLocationForDirectInteraction(location)

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
        updatePointerLocationForDirectInteraction(location)
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

    @objc
    func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
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

        let rawLocation = gesture.location(in: self)
        let location = normalizedLocation(rawLocation)
        let eventModifiers = modifiers(from: gesture)

        if gesture.numberOfTouches > 1 {
            if longPressButtonDown {
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: location,
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
        if requestCursorLockRecaptureIfNeeded() { return }

        let location: CGPoint
        if cursorLockEnabled {
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition()
        } else {
            location = normalizedLocation(gesture.location(in: self))
        }
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
        let translation = gesture.translation(in: self)
        let location = updatePointerLocationForScrollInteraction(gesture.location(in: self))

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
        let hoverStylus = pencilInputMode == .drawingTablet ? stylusHoverEvent(from: gesture) : nil
        let stylusPayload = hoverStylus
        let hoverPressure: CGFloat = stylusPayload == nil ? 1.0 : 0.0
        let location = gesture.location(in: self)

        if cursorLockEnabled {
            guard !usesMouseInputDeltas else { return }
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
                    return
                }
                if let lastLocation = lockedPointerLastHoverLocation {
                    if shouldIgnoreLockedPointerHoverJump(from: lastLocation, to: location) {
                        lockedPointerLastHoverLocation = nil
                        return
                    }
                    let translation = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
                    if translation != .zero {
                        scrollPhysicsView?.stopIndirectScrollDeceleration()
                        if stylusPayload == nil { revealCursorAfterPointerMovement() }
                        noteLockedPointerDragIfNeeded(for: translation)
                        applyLockedCursorDelta(translation)
                        let eventModifiers = modifiers(from: gesture)
                        sendLockedPointerMovementEvent(
                            location: lockedCursorPosition,
                            modifiers: eventModifiers,
                            pressure: hoverPressure,
                            stylus: stylusPayload
                        )
                    }
                }
                lockedPointerLastHoverLocation = location
            default:
                lockedPointerLastHoverLocation = nil
            }
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
            if pointerMoved, stylusPayload == nil { revealCursorAfterPointerMovement() }
            if usesVirtualTrackpad {
                setVirtualCursorVisible(false)
                updateVirtualCursorPosition(normalized, updateVisibility: false)
            }

            // Track cursor position for scroll events
            lastCursorPosition = normalized

            // Only send mouse moved if not dragging (pan gesture handles that)
            if !isDragging {
                let eventModifiers = modifiers(from: gesture)
                let mouseEvent = MirageMouseEvent(
                    button: .left,
                    location: normalized,
                    modifiers: eventModifiers,
                    pressure: hoverPressure,
                    stylus: stylusPayload
                )
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
            if !virtualDragActive { startVirtualCursorDeceleration(with: gesture.velocity(in: self)) }
        default:
            break
        }
    }

    @objc
    func handleVirtualCursorLongPress(_ gesture: UILongPressGestureRecognizer) {
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
        let location = normalizedLocation(gesture.location(in: self))
        updateTrackpadCursorPosition(location, updateVisibility: false)
        let eventModifiers = modifiers(from: gesture)

        switch gesture.state {
        case .began:
            virtualDragActive = true
            resetPrimaryClickTracking()
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: trackpadCursorActionPosition(),
                clickCount: 1,
                modifiers: eventModifiers
            )
            onInputEvent?(.mouseDown(mouseEvent))
        case .cancelled,
             .ended:
            let mouseEvent = MirageMouseEvent(
                button: .left,
                location: trackpadCursorActionPosition(),
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
        if requestCursorLockRecaptureIfNeeded() { return }
        stopVirtualCursorDeceleration()
        setTrackpadCursorVisible(true)
        let location = trackpadCursorActionPosition()

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
    func handleVirtualCursorRightTap(_ gesture: UITapGestureRecognizer) {
        guard usesVirtualTrackpad else { return }
        if requestCursorLockRecaptureIfNeeded() { return }
        stopVirtualCursorDeceleration()
        setTrackpadCursorVisible(true)
        let location = trackpadCursorActionPosition()

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
            moveTrackpadCursor(by: translation)
            sendTrackpadMovementEvent(modifiers: keyboardModifiers)
        }

        let decay = CGFloat(pow(Double(decelerationRate), dt * 60))
        virtualCursorVelocity.x *= decay
        virtualCursorVelocity.y *= decay

        if hypot(virtualCursorVelocity.x, virtualCursorVelocity.y) < 5 { stopVirtualCursorDeceleration() }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InputCapturingView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let isStylus = isStylusTouch(touch)
        if touch.type == .direct, !isStylus { onDirectTouchActivity?() }
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

        return false
    }
}
#endif
