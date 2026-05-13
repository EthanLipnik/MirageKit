//
//  InputCapturingView+KeyRepeat.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(iOS) || os(visionOS)
import UIKit
import MirageKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
    // MARK: - Key Repeat

    /// Starts the key-repeat timer for a held hardware key.
    func startKeyRepeat(for press: UIPress) {
        guard let key = press.key else { return }
        let keyCode = key.keyCode

        stopKeyRepeat(for: keyCode)
        heldKeyPresses[keyCode] = press

        let initialTimer = Timer
            .scheduledTimer(withTimeInterval: Self.keyRepeatInitialDelay, repeats: false) { [weak self] _ in
                guard let self else { return }

                let repeatTimer = Timer
                    .scheduledTimer(withTimeInterval: Self.keyRepeatInterval, repeats: true) { [weak self] _ in
                        self?.fireKeyRepeat(for: keyCode)
                    }
                keyRepeatTimers[keyCode] = repeatTimer
                fireKeyRepeat(for: keyCode)
            }
        keyRepeatTimers[keyCode] = initialTimer
    }

    /// Stops key repeat for a hardware key.
    func stopKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        keyRepeatTimers[keyCode]?.invalidate()
        keyRepeatTimers.removeValue(forKey: keyCode)
        heldKeyPresses.removeValue(forKey: keyCode)
    }

    /// Emits one repeat key-down event when the held key is still eligible.
    func fireKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        syncModifiersForInput()
        if keyboardModifiers.contains(.command) {
            stopKeyRepeat(for: keyCode)
            return
        }
        guard let press = heldKeyPresses[keyCode] else {
            return
        }
        let keyEvent = hardwareKeyEvent(for: press, modifiers: keyboardModifiers, isRepeat: true)
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(keyEvent))
    }

    func hardwareKeyEvent(
        for press: UIPress,
        modifiers: MirageModifierFlags,
        isRepeat: Bool = false
    ) -> MirageKeyEvent {
        guard let key = press.key else {
            return MirageKeyEvent(
                keyCode: MirageKeyEvent.unicodeScalarFallbackKeyCode,
                modifiers: modifiers,
                isRepeat: isRepeat
            )
        }
        return MirageClientKeyEventBuilder.hardwareKeyEvent(
            keyCode: MirageKeyEvent.hidToMacKeyCode(key.keyCode),
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
    }

    /// Stops all active repeat timers and clears shortcut dispatch coalescing state.
    func stopAllKeyRepeats() {
        for (_, timer) in keyRepeatTimers {
            timer.invalidate()
        }
        keyRepeatTimers.removeAll()
        heldKeyPresses.removeAll()
        stopPassthroughShortcutRepeat(sendKeyUp: true)
        lastClientShortcutDispatch = nil
        lastPassthroughShortcutDispatch = nil
    }

    // MARK: - Intercepted Shortcut Repeat

    func sendPassthroughShortcutKeyDown(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags,
        isRepeat: Bool
    ) {
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(shortcut.keyDownEvent(baseModifiers: baseModifiers, isRepeat: isRepeat)))
    }

    func sendPassthroughShortcutKeyUp(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags
    ) {
        onInputEvent?(.keyUp(shortcut.keyUpEvent(baseModifiers: baseModifiers)))
    }

    func startPassthroughShortcutRepeatIfNeeded(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags
    ) -> Bool {
        guard shortcut.deliveryBehavior == .repeatable else { return false }
        let eventModifiers = shortcut.forwardedModifiers(baseModifiers: baseModifiers)

        if let existing = passthroughShortcutRepeatState {
            if existing.keyCode == shortcut.keyCode,
               existing.input == shortcut.input,
               existing.modifiers == eventModifiers {
                return true
            }
            stopPassthroughShortcutRepeat(sendKeyUp: true)
        }

        let requiresShift = shortcut.modifiers.contains(.shift)
        sendPassthroughShortcutKeyDown(
            shortcut: shortcut,
            baseModifiers: baseModifiers,
            isRepeat: false
        )

        guard isPassthroughShortcutHeld(requiresShift: requiresShift) else {
            sendPassthroughShortcutKeyUp(
                shortcut: shortcut,
                baseModifiers: baseModifiers
            )
            return true
        }

        passthroughShortcutRepeatState = PassthroughShortcutRepeatState(
            keyCode: shortcut.keyCode,
            input: shortcut.input,
            modifiers: eventModifiers,
            requiresShift: requiresShift,
            nextRepeatDeadline: Date.timeIntervalSinceReferenceDate + Self.keyRepeatInitialDelay
        )

        if passthroughShortcutRepeatTimer == nil {
            passthroughShortcutRepeatTimer = Timer
                .scheduledTimer(
                    withTimeInterval: Self.passthroughShortcutRepeatPollInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.tickPassthroughShortcutRepeat()
                }
        }

        return true
    }

    func tickPassthroughShortcutRepeat() {
        guard var state = passthroughShortcutRepeatState else {
            passthroughShortcutRepeatTimer?.invalidate()
            passthroughShortcutRepeatTimer = nil
            return
        }

        guard isPassthroughShortcutHeld(requiresShift: state.requiresShift) else {
            stopPassthroughShortcutRepeat(sendKeyUp: true)
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard now >= state.nextRepeatDeadline else { return }

        let shortcut = MirageInterceptedShortcut(
            input: state.input,
            keyCode: state.keyCode,
            modifiers: state.modifiers.normalizedForShortcutMatching,
            deliveryBehavior: .repeatable
        )
        sendPassthroughShortcutKeyDown(
            shortcut: shortcut,
            baseModifiers: state.modifiers.subtracting(shortcut.modifiers),
            isRepeat: true
        )
        state.nextRepeatDeadline = now + Self.keyRepeatInterval
        passthroughShortcutRepeatState = state
    }

    func stopPassthroughShortcutRepeat(sendKeyUp: Bool) {
        if sendKeyUp, let state = passthroughShortcutRepeatState {
            let shortcut = MirageInterceptedShortcut(
                input: state.input,
                keyCode: state.keyCode,
                modifiers: state.modifiers.normalizedForShortcutMatching,
                deliveryBehavior: .repeatable
            )
            sendPassthroughShortcutKeyUp(
                shortcut: shortcut,
                baseModifiers: state.modifiers.subtracting(shortcut.modifiers)
            )
        }

        passthroughShortcutRepeatState = nil
        passthroughShortcutRepeatTimer?.invalidate()
        passthroughShortcutRepeatTimer = nil
    }

    func isPassthroughShortcutHeld(requiresShift: Bool) -> Bool {
        #if canImport(GameController)
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        let commandHeld = keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true
            || keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true
        let zHeld = keyboardInput.button(forKeyCode: .keyZ)?.isPressed == true
        guard commandHeld, zHeld else { return false }
        if requiresShift {
            return keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true
                || keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true
        }
        return true
        #else
        return false
        #endif
    }
}
#endif
