//
//  MirageStreamContentView+InputForwarding.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import MirageKit
import SwiftUI

@MainActor
extension MirageStreamContentView {
    /// Schedules a stream refresh-rate override after the representable finishes its current update pass.
    func scheduleRefreshRateOverrideChange(_ maxRefreshRate: Int) {
        Task { @MainActor [clientService] in
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return
            }
            clientService.updateStreamRefreshRateOverride(
                streamID: session.streamID,
                maxRefreshRate: maxRefreshRate
            )
        }
    }

    /// Handles local shortcut interception before forwarding input to the host.
    func sendInputEvent(_ event: MirageInputEvent) {
        if case let .keyDown(keyEvent) = event {
            if desktopExitShortcut.matches(keyEvent), let onExitDesktopStream {
                logDesktopExitShortcutTriggered()
                onExitDesktopStream()
                return
            }

            if dictationShortcut.matches(keyEvent) {
                onToggleDictationShortcut?()
                return
            }
            if escapeRemapShortcut.matches(keyEvent) {
                if desktopCursorLockEnabled {
                    onCursorLockEscapeRequested?()
                    return
                }
                forwardInputEventToHost(.keyDown(remappedEscapeKeyEvent(isRepeat: keyEvent.isRepeat)))
                return
            }

            if isSharedClipboardPasteShortcut(keyEvent),
               clientService.sharedClipboardEnabled,
               clientService.clientClipboardSharingEnabled {
                suppressNextOrderedPasteKeyUp = true
                sendOrderedSharedClipboardPaste(keyEvent)
                return
            }
        } else if case let .keyUp(keyEvent) = event {
            if isSharedClipboardPasteShortcut(keyEvent), suppressNextOrderedPasteKeyUp {
                suppressNextOrderedPasteKeyUp = false
                return
            }
            if escapeRemapShortcut.matches(keyEvent) {
                guard !desktopCursorLockEnabled else { return }
                forwardInputEventToHost(.keyUp(remappedEscapeKeyEvent()))
                return
            }
        }

        if shouldSuppressDesktopPointerEventDuringResize(event) {
            MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                eventClass: event.latencyEventClass,
                streamID: session.streamID,
                source: "streamForwarder",
                reason: "desktopResizeMask",
                sourceTimestamp: event.timestamp
            )
            return
        }
        if shouldSuppressAppPointerEventDuringGeometryTransition(event) {
            MirageInputLatencyTelemetry.shared.recordClientSourceSuppression(
                eventClass: event.latencyEventClass,
                streamID: session.streamID,
                source: "streamForwarder",
                reason: "appGeometryTransition",
                sourceTimestamp: event.timestamp
            )
            return
        }

        forwardInputEventToHost(event)
    }

    /// Whether pointer movement should be blocked while the desktop resize mask is active.
    func shouldSuppressDesktopPointerEventDuringResize(_ event: MirageInputEvent) -> Bool {
        guard isDesktopStream,
              event.isPointerGeometryInput,
              awaitingPostResizeFirstFrame ||
              desktopResizeCoordinator.isResizing ||
              desktopResizeCoordinator.maskActive else {
            return false
        }
        return true
    }

    /// Whether app-stream pointer input should wait for current geometry to settle.
    func shouldSuppressAppPointerEventDuringGeometryTransition(_ event: MirageInputEvent) -> Bool {
        guard !isDesktopStream, event.isPointerGeometryInput else { return false }
        return localPresentationPauseActive ||
            awaitingAppResizeAck ||
            isResizing ||
            inputResumeBaselineSubmissionCursor != nil
    }

    /// Detects the platform Command-V shortcut that should sync clipboard before paste.
    func isSharedClipboardPasteShortcut(_ keyEvent: MirageKeyEvent) -> Bool {
        keyEvent.keyCode == 0x09 && keyEvent.modifiers.contains(.command)
    }

    /// Syncs local clipboard contents before sending the paste key down/up pair to the host.
    func sendOrderedSharedClipboardPaste(_ keyEvent: MirageKeyEvent) {
        let keyUpEvent = MirageKeyEvent(
            keyCode: keyEvent.keyCode,
            characters: keyEvent.characters,
            charactersIgnoringModifiers: keyEvent.charactersIgnoringModifiers,
            modifiers: keyEvent.modifiers,
            isRepeat: false
        )
        Task { @MainActor in
            let synced = await clientService.syncLocalClipboardToHost()
            guard synced else {
                MirageLogger.client("Suppressing paste shortcut because shared clipboard sync did not complete")
                return
            }
            MirageLogger.client("Forwarding paste shortcut after shared clipboard sync")
            forwardInputEventToHost(.keyDown(keyEvent))
            forwardInputEventToHost(.keyUp(keyUpEvent))
        }
    }

    /// Sends an input event to the host after focus/connection checks.
    func forwardInputEventToHost(_ event: MirageInputEvent) {
        guard canSendInputToHost else { return }

        #if os(macOS)
        guard sessionStore.focusedSessionID == session.id else { return }
        #else
        if sessionStore.focusedSessionID != session.id {
            MirageInputLatencyTelemetry.shared.recordClientSourceForward(
                event: event,
                streamID: session.streamID,
                source: "streamForwarder.focusCorrection",
                sourceTimestamp: event.timestamp
            )
            sessionStore.setFocusedSession(session.id)
            clientService.sendInputFireAndForget(.windowFocus, forStream: session.streamID)
        }
        #endif

        MirageInputLatencyTelemetry.shared.recordClientSourceForward(
            event: event,
            streamID: session.streamID,
            source: "streamForwarder",
            sourceTimestamp: event.timestamp
        )
        clientService.sendInputFireAndForget(event, forStream: session.streamID)
    }

    /// Escape key event used when the configured shortcut remaps to remote Escape.
    func remappedEscapeKeyEvent(isRepeat: Bool = false) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: 0x35,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            modifiers: [],
            isRepeat: isRepeat
        )
    }

    /// Handles shortcuts reserved by the local stream surface.
    func handleReservedShortcut(_ shortcut: MirageClientShortcut) {
        if shortcut == desktopExitShortcut {
            logDesktopExitShortcutTriggered()
            onExitDesktopStream?()
        } else if shortcut == escapeRemapShortcut {
            if desktopCursorLockEnabled {
                onCursorLockEscapeRequested?()
            } else {
                let escapeEvent = remappedEscapeKeyEvent()
                forwardInputEventToHost(.keyDown(escapeEvent))
                forwardInputEventToHost(.keyUp(escapeEvent))
            }
        } else if shortcut == dictationShortcut {
            onToggleDictationShortcut?()
        }
    }

    /// Logs a local desktop exit shortcut before invoking the exit action.
    func logDesktopExitShortcutTriggered() {
        guard isDesktopStream else { return }
        MirageLogger.client("Desktop exit shortcut triggered for stream \(session.streamID)")
    }
}

#if os(iOS) || os(visionOS)
@MainActor
extension MirageStreamContentView {
    /// Forwards Apple Pencil hardware gesture actions into stream shortcuts.
    func handlePencilGestureAction(_ action: MiragePencilGestureAction) {
        if action == .toggleDictation {
            onToggleDictationShortcut?()
        } else if case let .remoteShortcut(shortcut) = action {
            forwardInputEventToHost(.keyDown(shortcut.keyDownEvent()))
            forwardInputEventToHost(.keyUp(shortcut.keyUpEvent))
        }
    }
}
#endif

private extension MirageInputEvent {
    /// Whether the event depends on the current stream geometry.
    var isPointerGeometryInput: Bool {
        switch self {
        case .mouseDown,
             .mouseUp,
             .mouseMoved,
             .mouseDragged,
             .pointerSampleBatch,
             .rightMouseDown,
             .rightMouseUp,
             .rightMouseDragged,
             .otherMouseDown,
             .otherMouseUp,
             .otherMouseDragged,
             .scrollWheel,
             .magnify,
             .rotate,
             .swipe:
            true
        case .flagsChanged,
             .hostSystemAction,
             .keyDown,
             .keyUp,
             .pixelResize,
             .relativeResize,
             .windowFocus,
             .windowResize:
            false
        }
    }
}
