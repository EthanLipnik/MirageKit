//
//  ScrollPhysicsCapturingNSView+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Gestures

    override func scrollWheel(with event: NSEvent) {
        guard isInputProcessingActive else { return }

        let usesNativeScrollEventMetadata = UserDefaults.standard.bool(
            forKey: MirageNativeScrollEventMetadataPreference.defaultsKey
        )
        let phase = usesNativeScrollEventMetadata ? MirageScrollPhase(from: event.phase) : .none
        let momentumPhase = usesNativeScrollEventMetadata ? MirageScrollPhase(from: event.momentumPhase) : .none
        let isPrecise = event.hasPreciseScrollingDeltas

        if cursorLockEnabled {
            lastMouseLocation = lockedCursorPosition
        } else {
            let locationInView = convert(event.locationInWindow, from: nil)
            updateLocalMouseLocation(Self.normalizedLocation(
                locationInView,
                in: bounds,
                contentRect: resolvedDesktopPresentationContentRect
            ))
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        if deltaX != 0 || deltaY != 0 || phase != .none || momentumPhase != .none {
            let modifiers = MirageModifierFlags(nsEventFlags: event.modifierFlags)
            onScroll?(deltaX, deltaY, lastMouseLocation, phase, momentumPhase, modifiers, isPrecise)
        }
    }

    override func magnify(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        updateGestureLocation(from: event)
        onMouseEvent?(.magnify(MirageMagnifyEvent(
            magnification: event.magnification,
            location: lastMouseLocation,
            phase: MirageScrollPhase(from: event.phase),
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )))
    }

    override func smartMagnify(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        updateGestureLocation(from: event)
        onMouseEvent?(.magnify(MirageMagnifyEvent(
            magnification: 1,
            location: lastMouseLocation,
            phase: .changed,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )))
    }

    override func rotate(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        updateGestureLocation(from: event)
        onMouseEvent?(.rotate(MirageRotateEvent(
            rotation: CGFloat(event.rotation),
            location: lastMouseLocation,
            phase: MirageScrollPhase(from: event.phase),
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )))
    }

    override func swipe(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        updateGestureLocation(from: event)
        onMouseEvent?(.swipe(MirageSwipeEvent(
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            location: lastMouseLocation,
            phase: MirageScrollPhase(from: event.phase),
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags)
        )))
    }

    func updateGestureLocation(from event: NSEvent) {
        if cursorLockEnabled {
            lastMouseLocation = lockedCursorPosition
        } else {
            let locationInView = convert(event.locationInWindow, from: nil)
            updateLocalMouseLocation(Self.normalizedLocation(
                locationInView,
                in: bounds,
                contentRect: resolvedDesktopPresentationContentRect
            ))
        }
    }
}
#endif
