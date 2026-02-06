//
//  MirageHostInputController+PointerLerp.swift
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
    // MARK: - Pointer Lerp (runs on accessibilityQueue)

    func queuePointerLerp(
        _ type: CGEventType,
        _ event: MirageMouseEvent,
        _ frame: CGRect,
        windowID: WindowID,
        app: MirageApplication?,
        isDesktop: Bool
    ) {
        let now = CACurrentMediaTime()
        pointerLastInputTime = now
        pointerContext = PointerLerpContext(
            type: type,
            event: event,
            frame: frame,
            windowID: windowID,
            app: app,
            isDesktop: isDesktop
        )
        pointerTargetLocation = event.location

        if pointerCurrentLocation == nil || now - pointerLastSendTime > pointerStopDelay {
            pointerCurrentLocation = event.location
            pointerLastSendTime = now
            emitPointerEvent(at: event.location)
        }

        startPointerLerpTimerIfNeeded()
    }

    private func startPointerLerpTimerIfNeeded() {
        guard pointerLerpTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(pointerOutputIntervalMs)),
            repeating: .milliseconds(Int(pointerOutputIntervalMs)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.pointerLerpTick()
        }
        timer.resume()
        pointerLerpTimer = timer
    }

    private func stopPointerLerpTimer() {
        pointerLerpTimer?.cancel()
        pointerLerpTimer = nil
    }

    private func pointerLerpTick() {
        guard let target = pointerTargetLocation,
              let context = pointerContext else {
            stopPointerLerpTimer()
            return
        }

        let now = CACurrentMediaTime()
        let dt = max(0.001, min(now - pointerLastSendTime, 0.05))
        let alpha = min(1.0, dt / pointerLerpTimeConstant)
        let current = pointerCurrentLocation ?? target
        let next = lerp(current, target, alpha: alpha)

        pointerCurrentLocation = next
        pointerLastSendTime = now
        emitPointerEvent(at: next, using: context)

        let distance = hypot(target.x - next.x, target.y - next.y)
        if now - pointerLastInputTime > pointerStopDelay {
            if distance > pointerSnapThreshold {
                pointerCurrentLocation = target
                emitPointerEvent(at: target, using: context)
            }
            resetPointerLerp()
        }
    }

    private func emitPointerEvent(at location: CGPoint) {
        guard let context = pointerContext else { return }
        emitPointerEvent(at: location, using: context)
    }

    private func emitPointerEvent(at location: CGPoint, using context: PointerLerpContext) {
        let event = MirageMouseEvent(
            button: context.event.button,
            location: location,
            clickCount: context.event.clickCount,
            modifiers: context.event.modifiers,
            pressure: context.event.pressure,
            timestamp: Date.timeIntervalSinceReferenceDate
        )

        if context.isDesktop {
            let point = screenPoint(location, in: context.frame)
            CGWarpMouseCursorPosition(point)
            injectDesktopMouseEvent(context.type, event, at: point)
        } else {
            injectMouseEvent(context.type, event, context.frame, windowID: context.windowID, app: context.app)
        }
    }

    private func resetPointerLerp() {
        stopPointerLerpTimer()
        pointerContext = nil
        pointerCurrentLocation = nil
        pointerTargetLocation = nil
        pointerLastInputTime = 0
        pointerLastSendTime = 0
    }

    func flushPointerLerp() {
        guard let target = pointerTargetLocation,
              let context = pointerContext else {
            resetPointerLerp()
            return
        }

        pointerCurrentLocation = target
        emitPointerEvent(at: target, using: context)
        resetPointerLerp()
    }

    private func lerp(_ from: CGPoint, _ to: CGPoint, alpha: Double) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * alpha,
            y: from.y + (to.y - from.y) * alpha
        )
    }
}

#endif
