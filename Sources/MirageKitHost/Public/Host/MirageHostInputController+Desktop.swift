//
//  MirageHostInputController+Desktop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Desktop Input Handling

    /// Converts a Cocoa screen position to the CoreGraphics desktop injection coordinate space.
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

    /// Returns whether a desktop pointer event should warp the host cursor first.
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

    /// Resolves the injection point for desktop pointer events with host-context-sensitive buttons.
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

    /// Dispatches a desktop-stream input event into host input injection.
    func handleDesktopInputEvent(
        _ event: MirageInputEvent,
        bounds: CGRect,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }
            guard shouldProcessDeferredInput(deferredInjectionValidator) else { return }

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
            case let .pointerSampleBatch(batch):
                if batch.phase == .began {
                    clearUnexpectedSystemModifiers(domain: .hid)
                }
                injectDesktopPointerSampleBatch(batch, bounds: bounds)
            case let .rightMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseDragged, e, requestedPoint: point)
            case let .otherMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.otherMouseDragged, e, requestedPoint: point)
            case let .scrollWheel(e):
                injectDesktopScrollEvent(e, bounds: bounds)
            case let .magnify(e):
                injectMagnifyEvent(e, bounds: bounds, domain: .hid)
            case let .rotate(e):
                injectRotateEvent(e, bounds: bounds, domain: .hid)
            case let .swipe(e):
                injectSwipeEvent(e, bounds: bounds, domain: .hid)
            case let .hostSystemAction(request):
                executeHostSystemAction(request)
            case let .keyDown(e):
                injectKeyEvent(isKeyDown: true, e, domain: .hid)
            case let .keyUp(e):
                injectKeyEvent(isKeyDown: false, e, domain: .hid)
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, domain: .hid)
            case .pixelResize,
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

    /// Injects a desktop pointer event after resolving host cursor positioning rules.
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

    /// Injects a mouse event at a specific desktop screen point.
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

    /// Injects a scroll event in desktop screen coordinates.
    private func injectDesktopScrollEvent(_ event: MirageScrollEvent, bounds: CGRect) {
        let scrollPoint: CGPoint? = if let normalizedLocation = event.location {
            screenPoint(normalizedLocation, in: bounds)
        } else {
            nil
        }

        let integerDeltaX = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: event.deltaX,
            remainder: &directScrollRemainderX
        )
        let integerDeltaY = MirageHostScrollEventFactory.accumulatedIntegerDelta(
            for: event.deltaY,
            remainder: &directScrollRemainderY
        )

        guard let cgEvent = MirageHostScrollEventFactory.makeScrollEvent(
            from: event,
            integerDeltaX: integerDeltaX,
            integerDeltaY: integerDeltaY
        ) else {
            return
        }

        if let scrollPoint {
            cgEvent.location = scrollPoint
        }
        cgEvent.flags = event.modifiers.cgEventFlags
        postEvent(cgEvent)
    }
}

#endif
