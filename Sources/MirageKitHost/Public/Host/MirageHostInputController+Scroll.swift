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

    func injectScrollEvent(_ event: MirageScrollEvent, _ windowFrame: CGRect, app _: MirageApplication?) {
        let scrollPoint = if let normalizedLocation = event.location {
            CGPoint(
                x: windowFrame.origin.x + normalizedLocation.x * windowFrame.width,
                y: windowFrame.origin.y + normalizedLocation.y * windowFrame.height
            )
        } else {
            CGPoint(x: windowFrame.midX, y: windowFrame.midY)
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
        // Apply modifier flags so CMD+scroll zoom works in Preview/Safari
        cgEvent.flags = event.modifiers.cgEventFlags
        postEvent(cgEvent)
    }
}

#endif
