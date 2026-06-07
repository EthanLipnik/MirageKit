//
//  MirageHostInputController+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
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
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Gesture Injection (runs on accessibilityQueue)

    /// Injects a native magnify gesture at the stream-relative location.
    func injectMagnifyEvent(
        _ event: MirageInput.MirageMagnifyEvent,
        bounds: CGRect,
        domain: HostKeyboardInjectionDomain
    ) {
        let point = gesturePoint(event.location, in: bounds)
        guard HostPrivateGestureInjector.postMagnify(
            magnification: event.magnification,
            phase: event.phase,
            location: point,
            modifiers: event.modifiers,
            domain: domain
        ) else {
            MirageLogger.host("Native magnify gesture injection unavailable")
            return
        }
    }

    /// Injects a native rotate gesture at the stream-relative location.
    func injectRotateEvent(
        _ event: MirageInput.MirageRotateEvent,
        bounds: CGRect,
        domain: HostKeyboardInjectionDomain
    ) {
        let point = gesturePoint(event.location, in: bounds)
        guard HostPrivateGestureInjector.postRotate(
            rotation: event.rotation,
            phase: event.phase,
            location: point,
            modifiers: event.modifiers,
            domain: domain
        ) else {
            MirageLogger.host("Native rotate gesture injection unavailable")
            return
        }
    }

    /// Injects a native swipe gesture or maps it to a host system action.
    func injectSwipeEvent(
        _ event: MirageInput.MirageSwipeEvent,
        bounds: CGRect,
        domain: HostKeyboardInjectionDomain
    ) {
        if let action = Self.hostSystemAction(for: event) {
            executeHostSystemAction(MirageInput.MirageHostSystemActionRequest(action: action))
            return
        }

        let point = gesturePoint(event.location, in: bounds)
        guard HostPrivateGestureInjector.postSwipe(
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            phase: event.phase,
            location: point,
            modifiers: event.modifiers,
            domain: domain
        ) else {
            MirageLogger.host("Native swipe gesture injection unavailable")
            return
        }
    }

    /// Converts an optional normalized gesture location into a host screen point.
    private func gesturePoint(_ location: CGPoint?, in bounds: CGRect) -> CGPoint {
        guard let location else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return CGPoint(
            x: bounds.origin.x + location.x * bounds.width,
            y: bounds.origin.y + location.y * bounds.height
        )
    }

    /// Maps directional swipe deltas to host system actions when appropriate.
    nonisolated static func hostSystemAction(for event: MirageInput.MirageSwipeEvent) -> MirageInput.MirageHostSystemAction? {
        let absX = abs(event.deltaX)
        let absY = abs(event.deltaY)
        guard max(absX, absY) > 0 else { return nil }

        if absX >= absY {
            return event.deltaX < 0 ? .spaceRight : .spaceLeft
        }

        return event.deltaY > 0 ? .missionControl : .appExpose
    }
}

/// Posts private CoreGraphics gesture events for host-side trackpad gestures.
private enum HostPrivateGestureInjector {
    private static let gestureEventTypeRawValue: UInt32 = 29

    /// Private CoreGraphics fields used by gesture events.
    private enum Field: UInt32 {
        case gestureSubtype = 110
        case phase = 132
        case deltaX = 116
        case deltaY = 117
        case magnification = 113
        case rotation = 114
    }

    /// Private gesture subtype values understood by the window server.
    private enum GestureSubtype: Int64 {
        case magnify = 1
        case rotate = 2
        case swipe = 3
    }

    /// Posts a magnify gesture event.
    static func postMagnify(
        magnification: CGFloat,
        phase: MirageInput.MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) -> Bool {
        postGesture(
            subtype: .magnify,
            phase: phase,
            location: location,
            modifiers: modifiers,
            domain: domain
        ) { event in
            setDouble(.magnification, Double(magnification), on: event)
        }
    }

    /// Posts a rotate gesture event.
    static func postRotate(
        rotation: CGFloat,
        phase: MirageInput.MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) -> Bool {
        postGesture(
            subtype: .rotate,
            phase: phase,
            location: location,
            modifiers: modifiers,
            domain: domain
        ) { event in
            setDouble(.rotation, Double(rotation), on: event)
        }
    }

    /// Posts a swipe gesture event.
    static func postSwipe(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: MirageInput.MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) -> Bool {
        postGesture(
            subtype: .swipe,
            phase: phase,
            location: location,
            modifiers: modifiers,
            domain: domain
        ) { event in
            setDouble(.deltaX, Double(deltaX), on: event)
            setDouble(.deltaY, Double(deltaY), on: event)
        }
    }

    /// Builds, configures, and posts a private gesture event.
    private static func postGesture(
        subtype: GestureSubtype,
        phase: MirageInput.MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain,
        configure: (CGEvent) -> Void
    ) -> Bool {
        guard let rawType = CGEventType(rawValue: gestureEventTypeRawValue),
              let event = CGEvent(source: nil) else {
            return false
        }

        event.type = rawType
        event.location = location
        event.flags = modifiers.cgEventFlags
        setInteger(.gestureSubtype, subtype.rawValue, on: event)
        setInteger(.phase, Int64(phase.rawValue), on: event)
        configure(event)

        switch domain {
        case .session:
            MirageInjectedEventTag.postSession(event)
        case .hid:
            MirageInjectedEventTag.postHID(event)
        }
        return true
    }

    /// Sets an integer private gesture field when available.
    private static func setInteger(_ field: Field, _ value: Int64, on event: CGEvent) {
        guard let eventField = CGEventField(rawValue: field.rawValue) else { return }
        event.setIntegerValueField(eventField, value: value)
    }

    /// Sets a floating-point private gesture field when available.
    private static func setDouble(_ field: Field, _ value: Double, on event: CGEvent) {
        guard let eventField = CGEventField(rawValue: field.rawValue) else { return }
        event.setDoubleValueField(eventField, value: value)
    }
}
#endif
