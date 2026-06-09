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
        let updateStart = CFAbsoluteTimeGetCurrent()
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
        MirageCursorLatencyProbe.updateCursorImage(
            streamID: streamID,
            cursorType: cursorType,
            durationMilliseconds: MirageCursorLatencyProbe.elapsedMilliseconds(since: updateStart)
        )
    }

    func updateVirtualTrackpadMode() {
        let indirectTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]

        if usesLockedTrackpadCursor {
            clearDirectTouchCursorSuppression(reason: "lockedTrackpadModeEnabled")
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
            releaseActivePointerButtonsIfNeeded(reason: "locked_trackpad_mode_enabled")
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
            releaseActivePointerButtonsIfNeeded(reason: "cursor_lock_enabled")
            stopVirtualCursorDeceleration()
            setVirtualCursorVisible(false)
        } else {
            switch directTouchInputMode {
            case .dragCursor:
                clearDirectTouchCursorSuppression(reason: "dragCursorModeEnabled")
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
                setVirtualCursorVisible(false)
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
                releaseActivePointerButtonsIfNeeded(reason: "direct_touch_mode_enabled")
                stopVirtualCursorDeceleration()
                setVirtualCursorVisible(false)
            }
        }
    }

    func setVirtualCursorVisible(_ isVisible: Bool) {
        virtualTrackpadCursorActive = usesVirtualTrackpad && !cursorLockEnabled && isVisible
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
            releaseActivePointerButtonsIfNeeded(reason: "cursor_lock_disabled")
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
            invalidatePointerInteraction(reason: "cursorLockDisabled")
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

    func scrollEventLocation(
        source: ScrollPhysicsCapturingView.InputSource,
        phase: MirageScrollPhase = .none,
        momentumPhase: MirageScrollPhase = .none
    ) -> CGPoint? {
        switch source {
        case .directTouch:
            if let directTouchScrollAnchorLocation {
                return directTouchScrollAnchorLocation
            }
            if cursorLockEnabled {
                return lockedCursorPosition
            }
            return lastCursorPosition

        case .indirectPointer:
            guard !cursorLockEnabled else { return lockedCursorPosition }
            return lastCursorPosition
        }
    }

    func clearDirectTouchScrollAnchorIfNeeded(
        source: ScrollPhysicsCapturingView.InputSource,
        phase: MirageScrollPhase,
        momentumPhase: MirageScrollPhase
    ) {
        guard case .directTouch = source else { return }
        updateDirectTouchScrollMomentumState(phase: phase, momentumPhase: momentumPhase)
        let physicalScrollFinished = (phase == .ended || phase == .cancelled) && momentumPhase == .none
        let momentumFinished = momentumPhase == .ended || momentumPhase == .cancelled
        if physicalScrollFinished || momentumFinished {
            directTouchScrollAnchorLocation = nil
        }
    }

    func endInterruptedDirectTouchMomentumIfNeeded(modifiers: MirageModifierFlags) {
        guard directTouchScrollMomentumActive else { return }
        guard let directTouchScrollAnchorLocation else {
            directTouchScrollMomentumActive = false
            return
        }

        guard let scrollEvent = makeScrollEvent(
            deltaX: 0,
            deltaY: 0,
            location: directTouchScrollAnchorLocation,
            phase: .none,
            momentumPhase: .ended,
            modifiers: modifiers,
            isPrecise: true,
            preservePhaseMetadata: true
        ) else {
            directTouchScrollMomentumActive = false
            self.directTouchScrollAnchorLocation = nil
            return
        }
        onInputEvent?(.scrollWheel(scrollEvent))
        directTouchScrollMomentumActive = false
        self.directTouchScrollAnchorLocation = nil
    }

    func updateDirectTouchScrollMomentumState(
        phase: MirageScrollPhase,
        momentumPhase: MirageScrollPhase
    ) {
        if momentumPhase == .began || momentumPhase == .changed {
            directTouchScrollMomentumActive = true
        }
        if (phase == .ended || phase == .cancelled) && momentumPhase == .none {
            directTouchScrollMomentumActive = false
        }
        if momentumPhase == .ended || momentumPhase == .cancelled {
            directTouchScrollMomentumActive = false
        }
    }

    func makeScrollEvent(
        deltaX: CGFloat,
        deltaY: CGFloat,
        location: CGPoint?,
        phase: MirageScrollPhase = .none,
        momentumPhase: MirageScrollPhase = .none,
        modifiers: MirageModifierFlags,
        isPrecise: Bool,
        preservePhaseMetadata: Bool = false
    ) -> MirageScrollEvent? {
        let shouldPreservePhaseMetadata = usesNativeScrollEventMetadata || preservePhaseMetadata
        let resolvedPhase = shouldPreservePhaseMetadata ? phase : .none
        let resolvedMomentumPhase = shouldPreservePhaseMetadata ? momentumPhase : .none
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
        let location = if virtualPointerButtonDown {
            trackpadCursorActionPosition()
        } else {
            trackpadCursorPosition()
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: location,
            modifiers: modifiers
        )

        if virtualPointerButtonDown {
            onInputEvent?(.mouseDragged(mouseEvent))
        } else {
            onInputEvent?(.mouseMoved(mouseEvent))
        }
    }
}

#endif
