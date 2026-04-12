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
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.leftMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseUp(e):
                injectMouseEvent(.leftMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.rightMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseUp(e):
                injectMouseEvent(.rightMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.otherMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseUp(e):
                injectMouseEvent(.otherMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseMoved(e):
                injectMouseEvent(.mouseMoved, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseDragged(e):
                injectMouseEvent(.leftMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseDragged(e):
                injectMouseEvent(.rightMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseDragged(e):
                injectMouseEvent(.otherMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .scrollWheel(e):
                injectScrollEvent(e, windowFrame, app: window.application)
            case let .hostSystemAction(request):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
                executeHostSystemAction(request, domain: .session)
            case let .keyDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
                injectKeyEvent(
                    isKeyDown: true,
                    e,
                    domain: .session,
                    app: window.application
                )
            case let .keyUp(e):
                injectKeyEvent(
                    isKeyDown: false,
                    e,
                    domain: .session,
                    app: window.application
                )
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, domain: .session, app: window.application)
            case .magnify,
                 .rotate,
                 .pixelResize,
                 .relativeResize,
                 .windowResize:
                break
            case .windowFocus:
                performWindowActivation(
                    windowID: window.id,
                    app: window.application,
                    trigger: .windowFocus
                )
            }
        }
    }

    private func performWindowActivation(
        windowID: WindowID,
        app: MirageApplication?,
        trigger: HostInputActivationTrigger
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let action = HostInputActivationPolicy.action(
            for: trigger,
            lastActivationTime: lastWindowActivationTime,
            lastActivatedWindowID: lastActivatedWindowID,
            targetWindowID: windowID,
            now: now
        )

        switch action {
        case .none:
            MirageLogger.host("Window focus activation throttled for window \(windowID) (same-window)")
            return
        case .fullWindowRaise:
            if lastActivatedWindowID == windowID {
                MirageLogger.host("Window focus activation allowed for window \(windowID) (same-window)")
            } else {
                MirageLogger.host("Window focus activation immediate for window \(windowID) (cross-window)")
            }
            activateWindow(windowID: windowID, app: app)
        }

        lastWindowActivationTime = now
        lastActivatedWindowID = windowID
    }
}

#endif
