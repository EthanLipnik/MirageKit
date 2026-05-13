//
//  InputCapturingView+CursorPresentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func setupVirtualCursorView() {
        virtualCursorView.contentMode = .scaleAspectFit
        virtualCursorView.isUserInteractionEnabled = false
        virtualCursorView.isHidden = true
        updateCursorImage()
        addSubview(virtualCursorView)
    }

    func setupLockedCursorView() {
        lockedCursorView.contentMode = .scaleAspectFit
        lockedCursorView.isUserInteractionEnabled = false
        lockedCursorView.isHidden = true
        updateCursorImage()
        addSubview(lockedCursorView)
    }

    func updateCursorImage() {
        let cursorType = currentCursorType
        let image = UIImage(named: cursorType.cursorImageName, in: .module, compatibleWith: nil)
        for view in [virtualCursorView, lockedCursorView] {
            view.image = image
            if let image {
                view.bounds = CGRect(
                    origin: .zero,
                    size: image.size
                )
            }
        }
    }

    func updateVirtualTrackpadMode() {
        let indirectTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]

        if usesLockedTrackpadCursor {
            longPressGesture.allowedTouchTypes = indirectTouchTypes
            scrollGesture.isEnabled = true
            directRotationGesture.isEnabled = true
            scrollPhysicsView?.directTouchScrollEnabled = false
            directTapGesture.isEnabled = false
            directLongPressGesture.isEnabled = false
            directDoubleTapDragGesture.isEnabled = false
            directTwoFingerTapGesture.isEnabled = false
            directTwoFingerDragGesture.isEnabled = false
            virtualCursorPanGesture.isEnabled = true
            virtualCursorTapGesture.isEnabled = true
            virtualCursorRightTapGesture.isEnabled = true
            virtualCursorLongPressGesture.isEnabled = true
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            lastCursorPosition = lockedCursorPosition
            setVirtualCursorVisible(false)
        } else if cursorLockEnabled {
            longPressGesture.allowedTouchTypes = indirectTouchTypes
            scrollGesture.isEnabled = false
            directRotationGesture.isEnabled = false
            scrollPhysicsView?.directTouchScrollEnabled = true
            directTapGesture.isEnabled = true
            directLongPressGesture.isEnabled = true
            directDoubleTapDragGesture.isEnabled = true
            directTwoFingerTapGesture.isEnabled = true
            directTwoFingerDragGesture.isEnabled = true
            virtualCursorPanGesture.isEnabled = false
            virtualCursorTapGesture.isEnabled = false
            virtualCursorRightTapGesture.isEnabled = false
            virtualCursorLongPressGesture.isEnabled = false
            virtualDragActive = false
            stopVirtualCursorDeceleration()
            setVirtualCursorVisible(false)
        } else {
            switch directTouchInputMode {
            case .dragCursor:
                longPressGesture.allowedTouchTypes = indirectTouchTypes
                scrollGesture.isEnabled = true
                directRotationGesture.isEnabled = true
                scrollPhysicsView?.directTouchScrollEnabled = false
                directTapGesture.isEnabled = false
                directLongPressGesture.isEnabled = false
                directDoubleTapDragGesture.isEnabled = false
                directTwoFingerTapGesture.isEnabled = false
                directTwoFingerDragGesture.isEnabled = false
                virtualCursorPanGesture.isEnabled = true
                virtualCursorTapGesture.isEnabled = true
                virtualCursorRightTapGesture.isEnabled = true
                virtualCursorLongPressGesture.isEnabled = true
                lastCursorPosition = virtualCursorPosition
                setVirtualCursorVisible(true)
            case .normal:
                longPressGesture.allowedTouchTypes = indirectTouchTypes
                scrollGesture.isEnabled = false
                directRotationGesture.isEnabled = false
                scrollPhysicsView?.directTouchScrollEnabled = true
                directTapGesture.isEnabled = true
                directLongPressGesture.isEnabled = true
                directDoubleTapDragGesture.isEnabled = true
                directTwoFingerTapGesture.isEnabled = true
                directTwoFingerDragGesture.isEnabled = true
                virtualCursorPanGesture.isEnabled = false
                virtualCursorTapGesture.isEnabled = false
                virtualCursorRightTapGesture.isEnabled = false
                virtualCursorLongPressGesture.isEnabled = false
                virtualDragActive = false
                stopVirtualCursorDeceleration()
                setVirtualCursorVisible(false)
            }
        }
    }

    func setVirtualCursorVisible(_ isVisible: Bool) {
        guard usesVisibleVirtualCursor else {
            virtualCursorView.isHidden = true
            return
        }
        virtualCursorView.isHidden = !syntheticCursorEnabled || !isVisible
        updateVirtualCursorViewPosition()
    }

    func updateVirtualCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !virtualCursorView.isHidden else { return }
        let hotspot = currentCursorType.cursorHotspot
        let point = Self.localPoint(
            forNormalizedPosition: virtualCursorPosition,
            in: bounds,
            contentRect: resolvedPresentationContentRect()
        )
        virtualCursorView.frame.origin = CGPoint(
            x: point.x - hotspot.x,
            y: point.y - hotspot.y
        )
    }

    func updateCursorLockMode() {
        updateVirtualTrackpadMode()
        // Locked cursor mode uses the dedicated locked-pointer recognizers.
        // The generic indirect long-press recognizer can still receive absolute
        // pointer coordinates from UIKit, which can yank the locked cursor to an edge.
        longPressGesture.isEnabled = !cursorLockEnabled
        if cursorLockEnabled {
            updateMouseInputHandler()
            hoverGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPressGesture.isEnabled = true
            lockedPointerLastHoverLocation = nil
            startLockedCursorSmoothingIfNeeded()
            _ = refreshLockedCursorIfNeeded(force: true)
            if syntheticCursorEnabled {
                lockedCursorVisible = effectiveCursorVisibility(
                    hostVisibility: lockedCursorVisible || cursorIsVisible
                )
            }
            setLockedCursorVisible(lockedCursorVisible)
        } else {
            updateMouseInputHandler()
            hoverGesture.isEnabled = true
            lockedPointerPanGesture.isEnabled = false
            lockedPointerPressGesture.isEnabled = false
            lockedPointerButtonDown = false
            lockedPointerDraggedSinceDown = false
            lockedPointerLastHoverLocation = nil
            stopLockedCursorSmoothing()
            setLockedCursorVisible(false)
            // Force UIKit to re-query the pointer style so the system cursor
            // becomes visible again now that cursor lock is off.
            pointerInteraction?.invalidate()
        }
    }

    func handlePointerLockStateChange() {
        guard cursorLockEnabled else { return }
        updateMouseInputHandler()
        hoverGesture.isEnabled = !usesMouseInputDeltas
        lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
        _ = refreshLockedCursorIfNeeded(force: true)
        updateLockedCursorViewVisibility()
    }

    func requestCursorLockRecaptureIfNeeded() -> Bool {
        guard canRecaptureCursorLock else { return false }
        onCursorLockRecaptureRequested?()
        return true
    }

    func requestCursorLockEscapeIfNeeded() -> Bool {
        guard cursorLockEnabled else { return false }
        onCursorLockEscapeRequested?()
        return true
    }

    func updatePointerLocationForLocalContact(_ location: CGPoint) {
        if cursorLockEnabled {
            lockedCursorPosition = location
            noteLockedCursorLocalInput()
            setLockedCursorVisible(true)
            updateLockedCursorViewPosition()
        }

        if usesVisibleVirtualCursor {
            updateVirtualCursorPosition(location, updateVisibility: true)
        }

        lastCursorPosition = cursorLockEnabled ? lockedCursorPosition : location
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func scrollEventLocation(source: ScrollPhysicsCapturingView.InputSource) -> CGPoint? {
        guard !cursorLockEnabled else { return lockedCursorPosition }

        switch source {
        case .directTouch:
            return lastCursorPosition

        case .indirectPointer:
            return lastCursorPosition
        }
    }

    func makeScrollEvent(
        deltaX: CGFloat,
        deltaY: CGFloat,
        location: CGPoint?,
        phase: MirageScrollPhase = .none,
        momentumPhase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags,
        isPrecise: Bool
    ) -> MirageScrollEvent? {
        let resolvedPhase = usesNativeScrollEventMetadata ? phase : .none
        let resolvedMomentumPhase = usesNativeScrollEventMetadata ? momentumPhase : .none
        guard deltaX != 0 || deltaY != 0 || resolvedPhase != .none || resolvedMomentumPhase != .none else {
            return nil
        }

        return MirageScrollEvent(
            deltaX: deltaX,
            deltaY: deltaY,
            location: location,
            phase: resolvedPhase,
            momentumPhase: resolvedMomentumPhase,
            modifiers: modifiers,
            isPrecise: isPrecise
        )
    }

    func setTrackpadCursorVisible(_ isVisible: Bool) {
        if usesLockedTrackpadCursor {
            setLockedCursorVisible(isVisible)
        } else {
            setVirtualCursorVisible(isVisible)
        }
    }

    func trackpadCursorPosition() -> CGPoint {
        if usesLockedTrackpadCursor {
            lockedCursorPosition
        } else {
            virtualCursorPosition
        }
    }

    func trackpadCursorActionPosition() -> CGPoint {
        if usesLockedTrackpadCursor {
            lockedCursorActionPosition()
        } else {
            virtualCursorPosition
        }
    }

    func updateTrackpadCursorPosition(_ position: CGPoint, updateVisibility: Bool) {
        if usesLockedTrackpadCursor {
            lockedCursorPosition = resolvedLockedCursorEventPosition(position)
            noteLockedCursorLocalInput()
            if updateVisibility {
                setLockedCursorVisible(true)
            } else {
                updateLockedCursorViewPosition()
            }
            lastCursorPosition = lockedCursorPosition
        } else {
            updateVirtualCursorPosition(position, updateVisibility: updateVisibility)
        }
    }

    func moveTrackpadCursor(by translation: CGPoint) {
        if usesLockedTrackpadCursor {
            applyLockedCursorDelta(translation)
        } else {
            moveVirtualCursor(by: translation)
        }
    }

    func sendTrackpadMovementEvent(modifiers: MirageModifierFlags) {
        let location = if virtualDragActive {
            trackpadCursorActionPosition()
        } else {
            trackpadCursorPosition()
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            modifiers: modifiers
        )

        if virtualDragActive {
            onInputEvent?(.mouseDragged(mouseEvent))
        } else {
            onInputEvent?(.mouseMoved(mouseEvent))
        }
    }
}

#endif
