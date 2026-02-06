//
//  MirageHostInputController+Input.swift
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
    // MARK: - Input Handling

    func handleInput(_ event: MirageInputEvent, window: MirageWindow) {
        let windowFrame = window.frame

        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case let .mouseDown(e):
                flushPointerLerp()
                clearUnexpectedSystemModifiers()
                activateWindow(windowID: window.id, app: window.application)
                injectMouseEvent(.leftMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseUp(e):
                flushPointerLerp()
                injectMouseEvent(.leftMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseDown(e):
                flushPointerLerp()
                clearUnexpectedSystemModifiers()
                activateWindow(windowID: window.id, app: window.application)
                injectMouseEvent(.rightMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseUp(e):
                flushPointerLerp()
                injectMouseEvent(.rightMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseDown(e):
                flushPointerLerp()
                clearUnexpectedSystemModifiers()
                activateWindow(windowID: window.id, app: window.application)
                injectMouseEvent(.otherMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseUp(e):
                flushPointerLerp()
                injectMouseEvent(.otherMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseMoved(e):
                queuePointerLerp(
                    .mouseMoved,
                    e,
                    windowFrame,
                    windowID: window.id,
                    app: window.application,
                    isDesktop: false
                )
            case let .mouseDragged(e):
                queuePointerLerp(
                    .leftMouseDragged,
                    e,
                    windowFrame,
                    windowID: window.id,
                    app: window.application,
                    isDesktop: false
                )
            case let .rightMouseDragged(e):
                queuePointerLerp(
                    .rightMouseDragged,
                    e,
                    windowFrame,
                    windowID: window.id,
                    app: window.application,
                    isDesktop: false
                )
            case let .otherMouseDragged(e):
                queuePointerLerp(
                    .otherMouseDragged,
                    e,
                    windowFrame,
                    windowID: window.id,
                    app: window.application,
                    isDesktop: false
                )
            case let .scrollWheel(e):
                batchScroll(e, windowFrame, app: window.application)
            case let .keyDown(e):
                flushPointerLerp()
                activateWindow(windowID: window.id, app: window.application)
                injectKeyEvent(isKeyDown: true, e, app: window.application)
            case let .keyUp(e):
                flushPointerLerp()
                injectKeyEvent(isKeyDown: false, e, app: window.application)
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, app: window.application)
            case let .magnify(e):
                handleMagnifyGesture(e, windowFrame: windowFrame)
            case let .rotate(e):
                handleRotateGesture(e, windowFrame: windowFrame)
            case .pixelResize,
                 .relativeResize,
                 .windowResize:
                break
            case .windowFocus:
                activateWindow(windowID: window.id, app: window.application)
            }
        }
    }
}

#endif
