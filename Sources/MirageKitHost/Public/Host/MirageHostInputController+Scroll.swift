//
//  MirageHostInputController+Scroll.swift
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
    // MARK: - Scroll Event Injection (runs on accessibilityQueue)

    /// Injects a scroll event at the resolved host-window location.
    func injectScrollEvent(
        _ event: MirageScrollEvent,
        _ windowFrame: CGRect,
        windowID: WindowID
    ) {
        let resolvedFrame = resolvedInputWindowFrame(for: windowID, streamFrame: windowFrame)
        let scrollPoint = Self.scrollInjectionPoint(event.location, in: resolvedFrame)

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

        cgEvent.location = scrollPoint
        cgEvent.flags = event.modifiers.cgEventFlags
        postEvent(cgEvent)
    }

    /// Converts an optional normalized scroll location into a host-window screen point.
    nonisolated static func scrollInjectionPoint(_ location: CGPoint?, in windowFrame: CGRect) -> CGPoint {
        let resolvedLocation = location ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(
            x: windowFrame.origin.x + resolvedLocation.x * windowFrame.width,
            y: windowFrame.origin.y + resolvedLocation.y * windowFrame.height
        )
    }
}

#endif
