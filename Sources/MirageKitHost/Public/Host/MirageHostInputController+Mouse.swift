//
//  MirageHostInputController+Mouse.swift
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
    // MARK: - Mouse Event Injection (runs on accessibilityQueue)

    func injectMouseEvent(
        _ type: CGEventType,
        _ event: MirageMouseEvent,
        _ windowFrame: CGRect,
        windowID: WindowID,
        app _: MirageApplication?
    ) {
        let actualFrame = currentWindowFrame(for: windowID)
        let useActualFrame = actualFrame.map { framesAreClose($0, windowFrame) } ?? false
        let resolvedFrame = useActualFrame ? (actualFrame ?? windowFrame) : windowFrame

        let screenPoint = CGPoint(
            x: resolvedFrame.origin.x + event.location.x * resolvedFrame.width,
            y: resolvedFrame.origin.y + event.location.y * resolvedFrame.height
        )

        switch type {
        case .leftMouseDown,
             .otherMouseDown,
             .rightMouseDown:
            CGWarpMouseCursorPosition(screenPoint)
        default:
            break
        }

        let pixelX = event.location.x * resolvedFrame.width
        let pixelY = event.location.y * resolvedFrame.height
        if pixelX < 80, pixelY < 30, type == .leftMouseDown || type == .leftMouseUp {
            MirageLogger.host("Blocked click in traffic light area")
            return
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: screenPoint,
            mouseButton: event.button.cgMouseButton
        ) else {
            return
        }

        switch type {
        case .leftMouseDown,
             .leftMouseUp,
             .otherMouseDown,
             .otherMouseUp,
             .rightMouseDown,
             .rightMouseUp:
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        default:
            break
        }

        postEvent(cgEvent)
    }
}

#endif
