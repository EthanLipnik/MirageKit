//
//  ScrollPhysicsCapturingNSView+Keyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Keyboard Event Handling

    /// Intercept key equivalents before AppKit's menu bar dispatching.
    /// Client-reserved shortcuts (exit stream, dictation toggle) are handled locally.
    /// All other key equivalents (including Cmd+Q, Cmd+W) are forwarded to the host.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isInputProcessingActive else { return super.performKeyEquivalent(with: event) }

        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: event.isARepeat
        )

        // Check if this matches a unified action
        for action in actions {
            guard let binding = action.shortcut else { continue }
            if binding.matches(keyEvent) {
                onActionTriggered?(action)
                return true
            }
        }

        // Check if this matches a client-reserved shortcut
        for shortcut in clientShortcuts where shortcut.matches(keyEvent) {
            onClientShortcut?(shortcut)
            return true
        }

        // Forward all other key equivalents to the host
        hideCursorForTypingUntilPointerMovement()
        onMouseEvent?(.keyDown(keyEvent))
        onMouseEvent?(.keyUp(MirageKeyEvent(
            keyCode: keyEvent.keyCode,
            characters: keyEvent.characters,
            charactersIgnoringModifiers: keyEvent.charactersIgnoringModifiers,
            modifiers: keyEvent.modifiers
        )))
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            syncModifierStateFromSystem(force: true)
            updateShortcutForwardingEventTap()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        // Clear modifier state when losing focus to prevent stuck modifiers
        syncModifierState([], force: true)
        let resignedFirstResponder = super.resignFirstResponder()
        updateShortcutForwardingEventTap()
        return resignedFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        if event.keyCode == 53, requestCursorLockEscapeIfNeeded(for: event) {
            suppressEscapeKeyUpForCursorUnlock = true
            syncModifierState([], force: true)
            return
        }
        hideCursorForTypingUntilPointerMovement()
        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: event.isARepeat
        )
        onMouseEvent?(.keyDown(keyEvent))
    }

    override func keyUp(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        if event.keyCode == 53, suppressEscapeKeyUpForCursorUnlock {
            suppressEscapeKeyUpForCursorUnlock = false
            return
        }
        let keyEvent = MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: false
        )
        onMouseEvent?(.keyUp(keyEvent))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        syncModifierState(MirageModifierFlags(nsEventFlags: event.modifierFlags), force: true)
    }
}
#endif
