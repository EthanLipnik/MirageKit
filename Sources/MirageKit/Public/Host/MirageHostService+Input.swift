//
//  MirageHostService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import CoreGraphics

#if os(macOS)

// MARK: - Input Handling

extension MirageHostService {
    /// Handle input events for the login display
    func handleLoginDisplayInputEvent(
        _ event: MirageInputEvent,
        loginInfo: (bounds: CGRect, lastCursorPosition: CGPoint, hasCursorPosition: Bool)
    ) {
        let bounds = loginInfo.bounds

        func loginDisplayPoint(_ location: CGPoint) -> CGPoint {
            CGPoint(
                x: bounds.origin.x + location.x * bounds.width,
                y: bounds.origin.y + location.y * bounds.height
            )
        }

        func warpCursorIfNeeded(to point: CGPoint, type: CGEventType) {
            switch type {
            case .leftMouseDown, .leftMouseUp,
                 .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp,
                 .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                CGWarpMouseCursorPosition(point)
            default:
                break
            }
        }

        switch event {
        case .mouseDown(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .leftMouseDown)
            postHIDMouseEvent(.leftMouseDown, event: e, location: point)
        case .mouseUp(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .leftMouseUp)
            postHIDMouseEvent(.leftMouseUp, event: e, location: point)
        case .mouseMoved(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .mouseMoved)
            postHIDMouseEvent(.mouseMoved, event: e, location: point)
        case .mouseDragged(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .leftMouseDragged)
            postHIDMouseEvent(.leftMouseDragged, event: e, location: point)
        case .rightMouseDown(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseDown)
            postHIDMouseEvent(.rightMouseDown, event: e, location: point)
        case .rightMouseUp(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseUp)
            postHIDMouseEvent(.rightMouseUp, event: e, location: point)
        case .rightMouseDragged(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseDragged)
            postHIDMouseEvent(.rightMouseDragged, event: e, location: point)
        case .otherMouseDown(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseDown)
            postHIDMouseEvent(.otherMouseDown, event: e, location: point)
        case .otherMouseUp(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseUp)
            postHIDMouseEvent(.otherMouseUp, event: e, location: point)
        case .otherMouseDragged(let e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseDragged)
            postHIDMouseEvent(.otherMouseDragged, event: e, location: point)
        case .scrollWheel(let e):
            let location = loginInfo.hasCursorPosition
                ? loginInfo.lastCursorPosition
                : CGPoint(x: bounds.midX, y: bounds.midY)
            postHIDScrollEvent(e, location: location)
        case .keyDown(let e):
            postHIDKeyEvent(isKeyDown: true, event: e)
        case .keyUp(let e):
            postHIDKeyEvent(isKeyDown: false, event: e)
        case .flagsChanged(let modifiers):
            postHIDFlagsChanged(modifiers)
        case .magnify, .rotate, .windowResize, .relativeResize, .pixelResize, .windowFocus:
            break
        }
    }

    /// Post a HID mouse event
    func postHIDMouseEvent(_ type: CGEventType, event: MirageMouseEvent, location: CGPoint) {
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: event.button.cgMouseButton
        ) else { return }

        cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        cgEvent.flags = event.modifiers.cgEventFlags
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Post a HID scroll event
    func postHIDScrollEvent(_ event: MirageScrollEvent, location: CGPoint) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else { return }

        cgEvent.location = location
        cgEvent.flags = event.modifiers.cgEventFlags
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Post a HID keyboard event
    func postHIDKeyEvent(isKeyDown: Bool, event: MirageKeyEvent) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isKeyDown
        ) else { return }

        cgEvent.flags = event.modifiers.cgEventFlags
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Post a HID flags changed event (modifier keys)
    func postHIDFlagsChanged(_ modifiers: MirageModifierFlags) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ) else { return }

        cgEvent.type = .flagsChanged
        cgEvent.flags = modifiers.cgEventFlags
        cgEvent.post(tap: .cghidEventTap)
    }
}

#endif
