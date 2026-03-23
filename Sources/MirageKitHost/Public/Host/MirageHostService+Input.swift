//
//  MirageHostService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

// MARK: - Input Handling

extension MirageHostService {
    /// Post a HID mouse event
    nonisolated func postHIDMouseEvent(_ type: CGEventType, event: MirageMouseEvent, location: CGPoint) {
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: event.button.cgMouseButton
        ) else {
            return
        }

        cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        cgEvent.flags = event.modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

    /// Post a HID scroll event
    nonisolated func postHIDScrollEvent(_ event: MirageScrollEvent, location: CGPoint) {
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

        cgEvent.location = location
        cgEvent.flags = event.modifiers.cgEventFlags
        MirageInjectedEventTag.postHID(cgEvent)
    }

}

#endif
