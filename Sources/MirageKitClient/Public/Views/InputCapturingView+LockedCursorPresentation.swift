//
//  InputCapturingView+LockedCursorPresentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
    func setLockedCursorVisible(_ isVisible: Bool) {
        lockedCursorVisible = effectiveCursorVisibility(hostVisibility: isVisible)
        updateLockedCursorViewVisibility()
        updateLockedCursorViewPosition()
    }

    func effectiveCursorVisibility(hostVisibility: Bool) -> Bool {
        if syntheticCursorEnabled, hideSystemCursor || cursorLockEnabled {
            return true
        }
        return hostVisibility
    }

    var unlockedSyntheticCursorPosition: CGPoint? {
        guard syntheticCursorEnabled,
              hideSystemCursor,
              !cursorLockEnabled,
              !usesVisibleVirtualCursor,
              !cursorHiddenByLocalInput,
              cursorIsVisible else {
            return nil
        }

        return lastCursorPosition ?? lockedCursorPosition
    }

    func updateLockedCursorViewVisibility() {
        let shouldShow = !cursorHiddenByLocalInput &&
            ((cursorLockEnabled && syntheticCursorEnabled && lockedCursorVisible) ||
                unlockedSyntheticCursorPosition != nil)
        lockedCursorView.isHidden = !shouldShow
    }

    func resolvedLockedCursorEventPosition(_ position: CGPoint) -> CGPoint {
        LockedCursorPositionResolver.resolve(position, allowsExtendedBounds: allowsExtendedCursorBounds)
    }

    func lockedCursorActionPosition() -> CGPoint {
        resolvedLockedCursorEventPosition(lockedCursorPosition)
    }

    func shouldIgnoreLockedPointerHoverJump(from lastLocation: CGPoint, to location: CGPoint) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let translation = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
        let distance = hypot(translation.x, translation.y)
        let jumpThreshold = max(bounds.width, bounds.height) * 0.35
        let edgeInset: CGFloat = 2
        let landsOnEdge = location.x <= edgeInset ||
            location.x >= bounds.width - edgeInset ||
            location.y <= edgeInset ||
            location.y >= bounds.height - edgeInset

        return landsOnEdge && distance >= jumpThreshold
    }

    func updateLockedCursorViewPosition() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !lockedCursorView.isHidden else { return }
        let contentRect = resolvedPresentationContentRect()
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        let position = if cursorLockEnabled {
            lockedCursorPosition
        } else if let unlockedSyntheticCursorPosition {
            unlockedSyntheticCursorPosition
        } else {
            lockedCursorPosition
        }
        let point = Self.localPoint(
            forNormalizedPosition: position,
            in: bounds,
            contentRect: contentRect
        )
        let hotspot = currentCursorType.cursorHotspot
        lockedCursorView.frame.origin = CGPoint(
            x: point.x - hotspot.x,
            y: point.y - hotspot.y
        )
    }

    func applyLockedCursorDelta(_ translation: CGPoint) {
        let contentRect = resolvedPresentationContentRect()
        let fallbackNormalizationSize = contentRect.width > 0 && contentRect.height > 0
            ? contentRect.size
            : bounds.size
        let normalizationSize = hostDisplayPointSize ?? fallbackNormalizationSize
        revealCursorAfterCursorDrivenMovement()
        lockedCursorPosition = LockedCursorPositionResolver.applyRelativeDelta(
            currentPosition: lockedCursorPosition,
            deltaX: translation.x,
            deltaY: translation.y,
            normalizationSize: normalizationSize,
            allowsExtendedBounds: allowsExtendedCursorBounds,
            confirmedHostPosition: lockedCursorConfirmedHostPosition
        )
        noteLockedCursorLocalInput()
        setLockedCursorVisible(true)
        lastCursorPosition = lockedCursorPosition
    }

    func applyLockedCursorHostUpdate(position: CGPoint, isVisible: Bool) {
        lockedCursorTargetPosition = resolvedLockedCursorEventPosition(position)
        lockedCursorConfirmedHostPosition = lockedCursorTargetPosition
        let visible = effectiveCursorVisibility(hostVisibility: isVisible)
        lockedCursorTargetVisible = visible
        guard cursorLockEnabled else { return }
        guard !isLockedCursorLocalInputActive() else { return }
        setLockedCursorVisible(visible)
        guard visible else { return }
        applyLockedCursorTargetStep()
    }

    func applyLockedCursorTargetStep() {
        let deltaX = lockedCursorTargetPosition.x - lockedCursorPosition.x
        let deltaY = lockedCursorTargetPosition.y - lockedCursorPosition.y
        let distance = hypot(deltaX, deltaY)
        if distance < lockedCursorStopThreshold { return }
        if distance > lockedCursorSnapThreshold {
            lockedCursorPosition = lockedCursorTargetPosition
        } else {
            lockedCursorPosition = CGPoint(
                x: lockedCursorPosition.x + deltaX * lockedCursorLerpAlpha,
                y: lockedCursorPosition.y + deltaY * lockedCursorLerpAlpha
            )
        }
        lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
        lastCursorPosition = lockedCursorPosition
        updateLockedCursorViewPosition()
    }

    func noteLockedCursorLocalInput() {
        lockedCursorLocalInputTime = CACurrentMediaTime()
        lockedCursorTargetPosition = lockedCursorPosition
        lockedCursorTargetVisible = true
    }

    func isLockedCursorLocalInputActive() -> Bool {
        let now = CACurrentMediaTime()
        return now - lockedCursorLocalInputTime < lockedCursorLocalHoldInterval
    }

    func startLockedCursorSmoothingIfNeeded() {
        guard lockedCursorDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleLockedCursorSmoothing(_:)))
        configureInteractionDisplayLink(displayLink)
        displayLink.add(to: .main, forMode: .common)
        lockedCursorDisplayLink = displayLink
    }

    func configureInteractionDisplayLink(_ displayLink: CADisplayLink) {
        let targetFPS = MirageInteractionCadence.targetFPS120
        let preferred = Float(targetFPS)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: preferred,
            maximum: preferred,
            preferred: preferred
        )
    }

    func stopLockedCursorSmoothing() {
        lockedCursorDisplayLink?.invalidate()
        lockedCursorDisplayLink = nil
    }

    @objc
    func handleLockedCursorSmoothing(_: CADisplayLink) {
        guard cursorLockEnabled else {
            stopLockedCursorSmoothing()
            return
        }
        guard !isLockedCursorLocalInputActive() else { return }
        guard lockedCursorTargetVisible else {
            setLockedCursorVisible(false)
            return
        }
        applyLockedCursorTargetStep()
    }

    func updateMouseInputHandler() {
        #if canImport(GameController)
        if cursorLockEnabled, pointerLockActive,
           let mouse = GCMouse.mice().first(where: { $0.mouseInput != nil }),
           let input = mouse.mouseInput {
            if mouseInput !== input {
                mouseInput?.mouseMovedHandler = nil
                mouseInput = input
            }
            usesMouseInputDeltas = true
            logMouseInputDeltaStatusIfNeeded("Pointer lock using GameController mouse delta input.")
            input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
                Task { @MainActor [weak self] in
                    self?.handleLockedMouseDelta(deltaX: deltaX, deltaY: deltaY)
                }
            }
        } else {
            usesMouseInputDeltas = false
            mouseInput?.mouseMovedHandler = nil
            mouseInput = nil
            if cursorLockEnabled, pointerLockActive {
                let status = if GCMouse.mice().isEmpty {
                    "Pointer lock waiting for connected mouse input."
                } else {
                    "Pointer lock waiting for usable GameController mouse input."
                }
                logMouseInputDeltaStatusIfNeeded(status)
            } else {
                lastLoggedMouseInputDeltaStatus = nil
            }
        }
        if cursorLockEnabled {
            hoverGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPanGesture.isEnabled = !usesMouseInputDeltas
            lockedPointerPressGesture.isEnabled = true
        }
        #else
        usesMouseInputDeltas = false
        #endif
    }

    func handleLockedMouseDelta(deltaX: Float, deltaY: Float) {
        guard cursorLockEnabled else { return }
        guard deltaX != 0 || deltaY != 0 else { return }
        revealCursorAfterPointerMovement()
        syncModifiersForInput()
        let translation = CGPoint(x: CGFloat(deltaX), y: CGFloat(-deltaY))
        noteLockedPointerDragIfNeeded(for: translation)
        applyLockedCursorDelta(translation)
        sendLockedPointerMovementEvent(location: lockedCursorPosition, modifiers: keyboardModifiers)
    }

    func noteLockedPointerDragIfNeeded(for translation: CGPoint) {
        guard translation != .zero else { return }

        if lockedPointerButtonDown, !lockedPointerDraggedSinceDown {
            lockedPointerDraggedSinceDown = true
            resetPrimaryClickTracking()
        }
    }

    func sendLockedPointerMovementEvent(
        location: CGPoint,
        modifiers: MirageModifierFlags,
        pressure: CGFloat = 1.0,
        stylus: MirageStylusEvent? = nil
    ) {
        let eventLocation = if lockedPointerButtonDown {
            lockedCursorActionPosition()
        } else {
            location
        }
        let mouseEvent = MirageMouseEvent(
            button: .left,
            location: eventLocation,
            modifiers: modifiers,
            pressure: pressure,
            stylus: stylus
        )

        if lockedPointerButtonDown {
            onInputEvent?(.mouseDragged(mouseEvent))
        } else {
            onInputEvent?(.mouseMoved(mouseEvent))
        }
    }

    #if canImport(GameController)
    func logMouseInputDeltaStatusIfNeeded(_ status: String) {
        guard lastLoggedMouseInputDeltaStatus != status else { return }
        lastLoggedMouseInputDeltaStatus = status
        MirageLogger.client(status)
    }
    #endif
}
#endif
