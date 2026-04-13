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

    nonisolated static func desktopInjectionCursorPosition(
        fromCocoaScreenPosition position: CGPoint,
        primaryDisplayHeight: CGFloat
    )
    -> CGPoint {
        CGPoint(
            x: position.x,
            y: primaryDisplayHeight - position.y
        )
    }

    nonisolated static func shouldWarpDesktopPointerEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            true
        default:
            false
        }
    }

    nonisolated static func resolvedDesktopPointerEventPoint(
        _ type: CGEventType,
        requestedPoint: CGPoint,
        currentCursorPosition: CGPoint
    )
    -> CGPoint {
        switch type {
        case .rightMouseDown, .rightMouseUp:
            currentCursorPosition
        default:
            requestedPoint
        }
    }

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
                injectDesktopPointerEvent(.leftMouseDown, e, requestedPoint: point)
            case let .mouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.leftMouseUp, e, at: point)
            case let .rightMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseDown, e, requestedPoint: point)
            case let .rightMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseUp, e, requestedPoint: point)
            case let .otherMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.otherMouseDown, e, requestedPoint: point)
            case let .otherMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.otherMouseUp, e, at: point)
            case let .mouseMoved(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.mouseMoved, e, requestedPoint: point)
            case let .mouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.leftMouseDragged, e, requestedPoint: point)
            case let .rightMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseDragged, e, requestedPoint: point)
            case let .otherMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.otherMouseDragged, e, requestedPoint: point)
            case let .scrollWheel(e):
                injectDesktopScrollEvent(e, bounds: bounds)
            case let .hostSystemAction(request):
                executeHostSystemAction(request)
            case let .keyDown(e):
                injectKeyEvent(isKeyDown: true, e, domain: .hid, app: nil)
            case let .keyUp(e):
                injectKeyEvent(isKeyDown: false, e, domain: .hid, app: nil)
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, domain: .hid, app: nil)
            case .magnify,
                 .rotate,
                 .pixelResize,
                 .relativeResize,
                 .windowResize:
                break
            case .windowFocus:
                break
            }
        }
    }

    /// Convert normalized stream coordinates to screen coordinates using display bounds.
    /// Secondary desktop cursor-lock travel may temporarily exceed `0...1`.
    func screenPoint(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.origin.x + normalized.x * bounds.width,
            y: bounds.origin.y + normalized.y * bounds.height
        )
    }

    private func injectDesktopPointerEvent(
        _ type: CGEventType,
        _ event: MirageMouseEvent,
        requestedPoint: CGPoint
    ) {
        let currentCursorPosition = Self.desktopInjectionCursorPosition(
            fromCocoaScreenPosition: NSEvent.mouseLocation,
            primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
        let point = Self.resolvedDesktopPointerEventPoint(
            type,
            requestedPoint: requestedPoint,
            currentCursorPosition: currentCursorPosition
        )
        if Self.shouldWarpDesktopPointerEvent(type) {
            CGWarpMouseCursorPosition(point)
        }
        injectDesktopMouseEvent(type, event, at: point)
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

        let rawX = event.deltaX + directScrollRemainderX
        let rawY = event.deltaY + directScrollRemainderY
        let truncX = rawX.rounded(.towardZero)
        let truncY = rawY.rounded(.towardZero)
        directScrollRemainderX = rawX - truncX
        directScrollRemainderY = rawY - truncY

        let intX = Int32(truncX)
        let intY = Int32(truncY)

        guard intX != 0 || intY != 0 else { return }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: intY,
            wheel2: intX,
            wheel3: 0
        ) else {
            return
        }

        cgEvent.location = scrollPoint
        cgEvent.flags = event.modifiers.cgEventFlags
        postEvent(cgEvent)
    }
}

#endif
