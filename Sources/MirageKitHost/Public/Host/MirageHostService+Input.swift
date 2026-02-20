//
//  MirageHostService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

// MARK: - Input Handling

extension MirageHostService {
    /// Handle input events for the login display
    nonisolated func handleLoginDisplayInputEvent(
        _ event: MirageInputEvent,
        loginInfo: (bounds: CGRect, lastCursorPosition: CGPoint, hasCursorPosition: Bool, hasReceivedFocusEvent: Bool)
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
            case .leftMouseDown,
                 .leftMouseDragged,
                 .leftMouseUp,
                 .mouseMoved,
                 .otherMouseDown,
                 .otherMouseDragged,
                 .otherMouseUp,
                 .rightMouseDown,
                 .rightMouseDragged,
                 .rightMouseUp:
                CGWarpMouseCursorPosition(point)
            default:
                break
            }
        }

        switch event {
        case let .mouseDown(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            loginDisplayInputState.markFocusReceived()
            warpCursorIfNeeded(to: point, type: .leftMouseDown)
            postHIDMouseEvent(.leftMouseDown, event: e, location: point)
        case let .mouseUp(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .leftMouseUp)
            postHIDMouseEvent(.leftMouseUp, event: e, location: point)
        case let .mouseMoved(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .mouseMoved)
            postHIDMouseEvent(.mouseMoved, event: e, location: point)
        case let .mouseDragged(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .leftMouseDragged)
            postHIDMouseEvent(.leftMouseDragged, event: e, location: point)
        case let .rightMouseDown(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseDown)
            postHIDMouseEvent(.rightMouseDown, event: e, location: point)
        case let .rightMouseUp(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseUp)
            postHIDMouseEvent(.rightMouseUp, event: e, location: point)
        case let .rightMouseDragged(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .rightMouseDragged)
            postHIDMouseEvent(.rightMouseDragged, event: e, location: point)
        case let .otherMouseDown(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseDown)
            postHIDMouseEvent(.otherMouseDown, event: e, location: point)
        case let .otherMouseUp(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseUp)
            postHIDMouseEvent(.otherMouseUp, event: e, location: point)
        case let .otherMouseDragged(e):
            let point = loginDisplayPoint(e.location)
            loginDisplayInputState.updateCursorPosition(point)
            warpCursorIfNeeded(to: point, type: .otherMouseDragged)
            postHIDMouseEvent(.otherMouseDragged, event: e, location: point)
        case let .scrollWheel(e):
            let location = loginInfo.hasCursorPosition
                ? loginInfo.lastCursorPosition
                : CGPoint(x: bounds.midX, y: bounds.midY)
            postHIDScrollEvent(e, location: location)
        case let .keyDown(e):
            // If first keyboard event without a prior mouse click, click to focus the login field
            if !loginInfo.hasReceivedFocusEvent {
                let centerPoint = CGPoint(x: bounds.midX, y: bounds.midY)
                clickToFocusLoginField(at: centerPoint)
            }
            postHIDKeyEvent(isKeyDown: true, event: e)
        case let .keyUp(e):
            postHIDKeyEvent(isKeyDown: false, event: e)
        case let .flagsChanged(modifiers):
            postHIDFlagsChanged(modifiers)
        case .magnify,
             .pixelResize,
             .relativeResize,
             .rotate,
             .windowFocus,
             .windowResize:
            break
        }
    }

    /// Post a HID mouse event
    nonisolated func postHIDMouseEvent(_ type: CGEventType, event: MirageMouseEvent, location: CGPoint) {
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: event.button.cgMouseButton
        ) else {
            return
        }

        cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        cgEvent.flags = event.modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

    /// Post a HID scroll event
    nonisolated func postHIDScrollEvent(_ event: MirageScrollEvent, location: CGPoint) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else {
            return
        }

        cgEvent.location = location
        cgEvent.flags = event.modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

    /// Post a HID keyboard event
    nonisolated func postHIDKeyEvent(isKeyDown: Bool, event: MirageKeyEvent) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isKeyDown
        ) else {
            return
        }

        cgEvent.flags = event.modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

    /// Post a HID flags changed event (modifier keys)
    nonisolated func postHIDFlagsChanged(_ modifiers: MirageModifierFlags) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ) else {
            return
        }

        cgEvent.type = .flagsChanged
        cgEvent.flags = modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

    /// Click to focus the login field before keyboard input.
    /// System-level UIs (login screen, screensaver) require a click to establish focus.
    nonisolated func clickToFocusLoginField(at point: CGPoint) {
        loginDisplayInputState.markFocusReceived()

        // Click at the center to focus the password field
        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        MirageInjectedEventTag.postHID(downEvent)

        guard let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        MirageInjectedEventTag.postHID(upEvent)
    }
}

#endif
