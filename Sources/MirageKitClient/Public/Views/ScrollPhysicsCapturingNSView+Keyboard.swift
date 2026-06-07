//
//  ScrollPhysicsCapturingNSView+Keyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
#if os(macOS)
import AppKit
import QuartzCore

extension ScrollPhysicsCapturingNSView {
    // MARK: - Keyboard Event Handling

    /// Intercepts key equivalents before AppKit's menu bar dispatching.
    /// Client-reserved shortcuts are handled locally; other key equivalents are forwarded to the host.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isInputProcessingActive else { return super.performKeyEquivalent(with: event) }

        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: event.isARepeat
        )

        // Check if this matches a unified action
        for action in actions {
            guard action.isEnabled else { continue }
            guard let binding = action.shortcut else { continue }
            if binding.matches(keyEvent) {
                onActionTriggered?(action)
                return true
            }
        }

        for shortcut in clientShortcuts where shortcut.matches(keyEvent) {
            onClientShortcut?(shortcut)
            return true
        }

        hideCursorForTypingUntilPointerMovement()
        onMouseEvent?(.keyDown(keyEvent))
        onMouseEvent?(.keyUp(MirageInput.MirageKeyEvent(
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
        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags),
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
        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags),
            isRepeat: false
        )
        onMouseEvent?(.keyUp(keyEvent))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isInputProcessingActive else { return }
        syncModifierState(MirageInput.MirageModifierFlags(nsEventFlags: event.modifierFlags), force: true)
    }
}
#endif
