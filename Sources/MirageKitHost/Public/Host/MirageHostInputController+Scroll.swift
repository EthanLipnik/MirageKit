//
//  MirageHostInputController+Scroll.swift
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
    // MARK: - Scroll Event Injection (runs on accessibilityQueue)

    func injectScrollEvent(
        _ event: MirageScrollEvent,
        _ windowFrame: CGRect,
        windowID: WindowID
    ) {
        let resolvedFrame = resolvedInputWindowFrame(for: windowID, streamFrame: windowFrame)
        let scrollPoint = Self.scrollInjectionPoint(event.location, in: resolvedFrame)

        // Accumulate fractional remainders so sub-pixel deltas aren't lost.
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
        // Apply modifier flags so CMD+scroll zoom works in Preview/Safari
        cgEvent.flags = event.modifiers.cgEventFlags
        postEvent(cgEvent)
    }

    nonisolated static func scrollInjectionPoint(_ location: CGPoint?, in windowFrame: CGRect) -> CGPoint {
        let resolvedLocation = location ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(
            x: windowFrame.origin.x + resolvedLocation.x * windowFrame.width,
            y: windowFrame.origin.y + resolvedLocation.y * windowFrame.height
        )
    }

}

#endif
