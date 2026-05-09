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

    private nonisolated static let desktopPointerWarpDiagnosticCornerInset: CGFloat = 24

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

    nonisolated static func shouldLogDesktopPointerWarpDiagnostic(point: CGPoint, bounds: CGRect) -> Bool {
        let inset = desktopPointerWarpDiagnosticCornerInset
        let nearLeft = point.x <= bounds.minX + inset
        let nearRight = point.x >= bounds.maxX - inset
        let nearTop = point.y <= bounds.minY + inset
        let nearBottom = point.y >= bounds.maxY - inset
        let outsideBounds = !bounds.insetBy(dx: -inset, dy: -inset).contains(point)

        return outsideBounds || ((nearLeft || nearRight) && (nearTop || nearBottom))
    }

    nonisolated static func logDesktopPointerWarpDiagnostic(
        source: String,
        type: CGEventType,
        normalizedLocation: CGPoint,
        point: CGPoint,
        currentCursorPosition: CGPoint,
        bounds: CGRect
    ) {
        guard shouldLogDesktopPointerWarpDiagnostic(point: point, bounds: bounds) else { return }

        let distance = hypot(point.x - currentCursorPosition.x, point.y - currentCursorPosition.y)
        MirageLogger.host(
            "Desktop pointer warp diagnostic source=\(source) type=\(desktopPointerWarpEventTypeDescription(type)) " +
                "normalized=\(desktopPointerWarpPointDescription(normalizedLocation)) " +
                "target=\(desktopPointerWarpPointDescription(point)) " +
                "current=\(desktopPointerWarpPointDescription(currentCursorPosition)) " +
                "bounds=\(desktopPointerWarpRectDescription(bounds)) " +
                "distance=\(desktopPointerWarpScalarDescription(distance)) " +
                "pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
    }

    private nonisolated static func desktopPointerWarpEventTypeDescription(_ type: CGEventType) -> String {
        switch type {
        case .leftMouseDown:
            "leftMouseDown"
        case .leftMouseUp:
            "leftMouseUp"
        case .rightMouseDown:
            "rightMouseDown"
        case .rightMouseUp:
            "rightMouseUp"
        case .otherMouseDown:
            "otherMouseDown"
        case .otherMouseUp:
            "otherMouseUp"
        case .mouseMoved:
            "mouseMoved"
        case .leftMouseDragged:
            "leftMouseDragged"
        case .rightMouseDragged:
            "rightMouseDragged"
        case .otherMouseDragged:
            "otherMouseDragged"
        default:
            "rawValue(\(type.rawValue))"
        }
    }

    private nonisolated static func desktopPointerWarpPointDescription(_ point: CGPoint) -> String {
        "(\(desktopPointerWarpScalarDescription(point.x)),\(desktopPointerWarpScalarDescription(point.y)))"
    }

    private nonisolated static func desktopPointerWarpRectDescription(_ rect: CGRect) -> String {
        "origin=\(desktopPointerWarpPointDescription(rect.origin)) " +
            "size=(\(desktopPointerWarpScalarDescription(rect.width)),\(desktopPointerWarpScalarDescription(rect.height)))"
    }

    private nonisolated static func desktopPointerWarpScalarDescription(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// Handle input events for desktop streaming.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - bounds: Bounds of the virtual display or mirrored desktop.
    public func handleDesktopInputEvent(_ event: MirageInputEvent, bounds: CGRect) {
        handleDesktopInputEvent(event, bounds: bounds, deferredInjectionValidator: nil)
    }

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
                injectDesktopPointerEvent(.leftMouseDown, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .mouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.leftMouseUp, e, at: point)
            case let .rightMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseDown, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .rightMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseUp, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .otherMouseDown(e):
                clearUnexpectedSystemModifiers(domain: .hid)
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.otherMouseDown, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .otherMouseUp(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopMouseEvent(.otherMouseUp, e, at: point)
            case let .mouseMoved(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.mouseMoved, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .mouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.leftMouseDragged, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .pointerSampleBatch(batch):
                if batch.phase == .began {
                    clearUnexpectedSystemModifiers(domain: .hid)
                }
                injectDesktopPointerSampleBatch(batch, bounds: bounds)
            case let .rightMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.rightMouseDragged, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
            case let .otherMouseDragged(e):
                let point = screenPoint(e.location, in: bounds)
                injectDesktopPointerEvent(.otherMouseDragged, e, requestedPoint: point, normalizedLocation: e.location, bounds: bounds)
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

    private func injectDesktopPointerEvent(
        _ type: CGEventType,
        _ event: MirageMouseEvent,
        requestedPoint: CGPoint,
        normalizedLocation: CGPoint,
        bounds: CGRect
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
            Self.logDesktopPointerWarpDiagnostic(
                source: "desktop-pointer",
                type: type,
                normalizedLocation: normalizedLocation,
                point: point,
                currentCursorPosition: currentCursorPosition,
                bounds: bounds
            )
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
