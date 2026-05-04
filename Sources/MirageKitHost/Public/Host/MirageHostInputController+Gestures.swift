//
//  MirageHostInputController+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Gesture Injection (runs on accessibilityQueue)

    func injectMagnifyEvent(
        _ event: MirageMagnifyEvent,
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

    func injectRotateEvent(
        _ event: MirageRotateEvent,
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

    func injectSwipeEvent(
        _ event: MirageSwipeEvent,
        bounds: CGRect,
        domain: HostKeyboardInjectionDomain
    ) {
        if let action = Self.hostSystemAction(for: event) {
            executeHostSystemAction(MirageHostSystemActionRequest(action: action))
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

    private func gesturePoint(_ location: CGPoint?, in bounds: CGRect) -> CGPoint {
        guard let location else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return CGPoint(
            x: bounds.origin.x + location.x * bounds.width,
            y: bounds.origin.y + location.y * bounds.height
        )
    }

    nonisolated static func hostSystemAction(for event: MirageSwipeEvent) -> MirageHostSystemAction? {
        let absX = abs(event.deltaX)
        let absY = abs(event.deltaY)
        guard max(absX, absY) > 0 else { return nil }

        if absX >= absY {
            return event.deltaX < 0 ? .spaceRight : .spaceLeft
        }

        return event.deltaY > 0 ? .missionControl : .appExpose
    }
}

private enum HostPrivateGestureInjector {
    private static let gestureEventTypeRawValue: UInt32 = 29

    private enum Field: UInt32 {
        case gestureSubtype = 110
        case phase = 132
        case deltaX = 116
        case deltaY = 117
        case magnification = 113
        case rotation = 114
    }

    private enum GestureSubtype: Int64 {
        case magnify = 1
        case rotate = 2
        case swipe = 3
    }

    static func postMagnify(
        magnification: CGFloat,
        phase: MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageModifierFlags,
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

    static func postRotate(
        rotation: CGFloat,
        phase: MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageModifierFlags,
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

    static func postSwipe(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageModifierFlags,
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

    private static func postGesture(
        subtype: GestureSubtype,
        phase: MirageScrollPhase,
        location: CGPoint,
        modifiers: MirageModifierFlags,
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

    private static func setInteger(_ field: Field, _ value: Int64, on event: CGEvent) {
        guard let eventField = CGEventField(rawValue: field.rawValue) else { return }
        event.setIntegerValueField(eventField, value: value)
    }

    private static func setDouble(_ field: Field, _ value: Double, on event: CGEvent) {
        guard let eventField = CGEventField(rawValue: field.rawValue) else { return }
        event.setDoubleValueField(eventField, value: value)
    }
}
#endif
