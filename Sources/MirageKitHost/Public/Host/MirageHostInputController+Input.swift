//
//  MirageHostInputController+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Input Handling

    /// Handles input for a window stream on the accessibility queue.
    func handleInput(
        _ event: MirageInput.MirageInputEvent,
        window: MirageMedia.MirageWindow,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) {
        let windowFrame = window.frame
        let enqueuedAt = Date.timeIntervalSinceReferenceDate

        accessibilityQueue.async { [weak self] in
            guard let self else { return }
            MirageInputLatencyTelemetry.shared.recordHostAccessibilityDwell(event: event, enqueuedAt: enqueuedAt)
            guard shouldProcessDeferredInput(deferredInjectionValidator) else { return }

            switch event {
            case let .mouseDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.leftMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseUp(e):
                injectMouseEvent(.leftMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.rightMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .rightMouseUp(e):
                injectMouseEvent(.rightMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
                clearUnexpectedSystemModifiers(domain: .session)
                injectMouseEvent(.otherMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseUp(e):
                injectMouseEvent(.otherMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseMoved(e):
                injectMouseEvent(.mouseMoved, e, windowFrame, windowID: window.id, app: window.application)
            case let .mouseDragged(e):
                injectMouseEvent(.leftMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .pointerSampleBatch(batch):
                if batch.phase == .began {
                    performWindowActivation(
                        windowID: window.id,
                        app: window.application
                    )
                    clearUnexpectedSystemModifiers(domain: .session)
                }
                injectPointerSampleBatch(
                    batch,
                    windowFrame: windowFrame,
                    windowID: window.id,
                    app: window.application
                )
            case let .rightMouseDragged(e):
                injectMouseEvent(.rightMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .otherMouseDragged(e):
                injectMouseEvent(.otherMouseDragged, e, windowFrame, windowID: window.id, app: window.application)
            case let .scrollWheel(e):
                if Self.shouldActivateWindowForScrollEvent(e) {
                    performWindowActivation(
                        windowID: window.id,
                        app: window.application
                    )
                }
                injectScrollEvent(e, windowFrame, windowID: window.id)
            case let .magnify(e):
                injectMagnifyEvent(e, bounds: windowFrame, domain: .session)
            case let .rotate(e):
                injectRotateEvent(e, bounds: windowFrame, domain: .session)
            case let .swipe(e):
                injectSwipeEvent(e, bounds: windowFrame, domain: .session)
            case let .hostSystemAction(request):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
                executeHostSystemAction(request)
            case let .keyDown(e):
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
                injectKeyEvent(
                    isKeyDown: true,
                    e,
                    domain: .session
                )
            case let .keyUp(e):
                injectKeyEvent(
                    isKeyDown: false,
                    e,
                    domain: .session
                )
            case let .flagsChanged(modifiers):
                injectFlagsChanged(modifiers, domain: .session)
            case .pixelResize,
                 .relativeResize,
                 .windowResize:
                break
            case .windowFocus:
                performWindowActivation(
                    windowID: window.id,
                    app: window.application
                )
            }
        }
    }

    /// Returns whether a scroll event should first activate its target window.
    nonisolated static func shouldActivateWindowForScrollEvent(_ event: MirageInput.MirageScrollEvent) -> Bool {
        if event.phase == .began { return true }
        return event.phase == .none && event.momentumPhase == .none
    }

    /// Activates a window with throttling for repeated same-window requests.
    private func performWindowActivation(
        windowID: WindowID,
        app: MirageMedia.MirageApplication?
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastActivatedWindowID == windowID,
           let lastWindowActivationTime,
           now - lastWindowActivationTime < 0.25 {
            MirageLogger.host("Window focus activation throttled for window \(windowID) (same-window)")
            return
        }

        if lastActivatedWindowID == windowID {
            MirageLogger.host("Window focus activation allowed for window \(windowID) (same-window)")
        } else {
            MirageLogger.host("Window focus activation immediate for window \(windowID) (cross-window)")
        }
        activateWindow(windowID: windowID, app: app)
        lastWindowActivationTime = now
        lastActivatedWindowID = windowID
    }
}

#endif
