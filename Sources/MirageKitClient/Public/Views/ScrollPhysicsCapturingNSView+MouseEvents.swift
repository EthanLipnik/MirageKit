//
//  ScrollPhysicsCapturingNSView+MouseEvents.swift
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
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Mouse Event Handling

    override func mouseDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        claimKeyboardFocusIfPossible()
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDown(mouseEvent))
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseUp(mouseEvent))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseDragged(mouseEvent))
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInputProcessingActive else { return }

        let location: CGPoint
        let movedByDelta = event.deltaX != 0 || event.deltaY != 0
        if cursorLockEnabled {
            if movedByDelta { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorPosition
        } else {
            location = normalizedLocation(from: event)
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            updateLocalMouseLocation(location)
        }

        guard movedByDelta else { return }

        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .left,
            location: location,
            clickCount: 0,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.mouseMoved(mouseEvent))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInputProcessingActive, !cursorLockEnabled else { return }
        updateLocalMouseLocation(normalizedLocation(from: event))
        applyMirroredSystemCursorAppearance()
    }

    override func mouseExited(with _: NSEvent) {
        guard isInputProcessingActive, !cursorLockEnabled else { return }
        updateLocalMouseLocation(nil)
        applyMirroredSystemCursorAppearance()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        claimKeyboardFocusIfPossible()
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDown(mouseEvent))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseUp(mouseEvent))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: .right,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.rightMouseDragged(mouseEvent))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        claimKeyboardFocusIfPossible()
        if requestCursorLockRecaptureIfNeeded() { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: MirageInput.MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseDown(mouseEvent))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            noteCursorLocalInput()
            setLockedCursorVisible(true)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: MirageInput.MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseUp(mouseEvent))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        let location: CGPoint
        if cursorLockEnabled {
            if event.deltaX != 0 || event.deltaY != 0 { revealCursorAfterPointerMovement() }
            applyLockedCursorDelta(dx: event.deltaX, dy: event.deltaY)
            location = lockedCursorActionPosition
        } else {
            location = normalizedLocation(from: event)
            let movedByDelta = event.deltaX != 0 || event.deltaY != 0
            let movedByLocation = if let lastMouseLocation {
                hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 0.0001
            } else {
                false
            }
            if movedByDelta || movedByLocation {
                noteCursorLocalInput()
                revealCursorAfterPointerMovement()
            }
            updateLocalMouseLocation(location)
        }
        let mouseEvent = MirageInput.MirageMouseEvent(
            button: MirageInput.MirageMouseButton(rawValue: event.buttonNumber) ?? .middle,
            location: location,
            clickCount: event.clickCount,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )
        onMouseEvent?(.otherMouseDragged(mouseEvent))
    }
}
#endif
