//
//  MirageHostInputController+Desktop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Desktop Input Handling

    /// Handle input events for desktop streaming.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - bounds: Bounds of the virtual display or mirrored desktop.
    public func handleDesktopInputEvent(_ event: MirageInputEvent, bounds: CGRect) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case let .mouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.leftMouseDown, e, at: point)
            case let .mouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.leftMouseUp, e, at: point)
            case let .rightMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.rightMouseDown, e, at: point)
            case let .rightMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.rightMouseUp, e, at: point)
            case let .otherMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.otherMouseDown, e, at: point)
            case let .otherMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.otherMouseUp, e, at: point)
            case let .mouseMoved(e):
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.mouseMoved, e, at: point)
            case let .mouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.leftMouseDragged, e, at: point)
            case let .rightMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.rightMouseDragged, e, at: point)
            case let .otherMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                injectDesktopMouseEvent(.otherMouseDragged, e, at: point)
            case let .scrollWheel(e):
                injectDesktopScrollEvent(e, bounds: bounds)
            case let .keyDown(e):
                injectKeyEvent(isKeyDown: true, e, domain: .hid, app: nil)
            case let .keyUp(e):
                injectKeyEvent(isKeyDown: false, e, domain: .hid, app: nil)
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, domain: .hid, app: nil)
            case let .magnify(e):
                handleMagnifyGesture(e, windowFrame: bounds)
            case let .rotate(e):
                handleRotateGesture(e, windowFrame: bounds)
            case .pixelResize,
                 .relativeResize,
                 .windowResize:
                break
            case .windowFocus:
                break
            }
        }
    }

    /// Convert normalized coordinates (0-1) to screen coordinates using display bounds.
    func screenPoint(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.origin.x + normalized.x * bounds.width,
            y: bounds.origin.y + normalized.y * bounds.height
        )
    }

    /// Inject mouse event at a specific screen point (for desktop streaming).
    func injectDesktopMouseEvent(_ type: CGEventType, _ event: MirageMouseEvent, at point: CGPoint) {
        refreshPointerModifierState(event.modifiers, domain: .hid)

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: event.button.cgMouseButton
        ) else {
            return
        }

        applyPointerEventMetadata(cgEvent, from: event, type: type)
        applyTabletFieldsIfNeeded(cgEvent, from: event, type: type, point: point)
        postStylusAwarePointerEvent(cgEvent, from: event, type: type, at: point)
    }

    /// Inject scroll event for desktop streaming.
    private func injectDesktopScrollEvent(_ event: MirageScrollEvent, bounds: CGRect) {
        let scrollPoint: CGPoint = if let normalizedLocation = event.location {
            screenPoint(normalizedLocation, in: bounds)
        } else {
            CGPoint(x: bounds.midX, y: bounds.midY)
        }

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

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }
}

#endif
