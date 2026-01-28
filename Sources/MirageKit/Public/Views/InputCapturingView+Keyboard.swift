//
//  InputCapturingView+Keyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    // MARK: - Keyboard Input (External Keyboard)

    private func modifierSnapshot(
        from event: UIPressesEvent?,
        fallbackFlags: UIKeyModifierFlags?,
        allowFallback: Bool
    ) -> UIKeyModifierFlags? {
        if let flags = event?.modifierFlags {
            return flags
        }
        if allowFallback {
            return fallbackFlags
        }
        return nil
    }

    private func sanitizedModifierFlags(
        _ flags: UIKeyModifierFlags,
        removing keyCode: UIKeyboardHIDUsage?
    ) -> UIKeyModifierFlags {
        guard let keyCode else { return flags }
        var sanitized = flags
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift:
            sanitized.remove(.shift)
        case .keyboardLeftControl, .keyboardRightControl:
            sanitized.remove(.control)
        case .keyboardLeftAlt, .keyboardRightAlt:
            sanitized.remove(.alternate)
        case .keyboardLeftGUI, .keyboardRightGUI:
            sanitized.remove(.command)
        case .keyboardCapsLock:
            sanitized.remove(.alphaShift)
        default:
            break
        }
        return sanitized
    }

    private func resyncModifiers(
        using event: UIPressesEvent?,
        fallbackFlags: UIKeyModifierFlags?,
        allowFallback: Bool,
        removing keyCode: UIKeyboardHIDUsage? = nil
    ) {
        if let flags = modifierSnapshot(from: event, fallbackFlags: fallbackFlags, allowFallback: allowFallback) {
            let sanitizedFlags = sanitizedModifierFlags(flags, removing: keyCode)
            resyncModifierState(from: sanitizedFlags)
        } else {
            sendModifierStateIfNeeded(force: true)
        }
    }

    private func updateModifierRefreshTimer() {
        if heldModifierKeys.isEmpty {
            stopModifierRefresh()
        } else {
            startModifierRefreshIfNeeded()
        }
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            if isCapsLockKey {
                capsLockEnabled.toggle()
                sendModifierStateIfNeeded(force: true)
                continue
            }

            if let modifierFlags = modifierSnapshot(from: event, fallbackFlags: fallbackFlags, allowFallback: true) {
                updateCapsLockState(from: modifierFlags)
            }
            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.insert(key.keyCode)
                resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true)
            } else {
                resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true)
                startKeyRepeat(for: press)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyDown(keyEvent))
                }
            }
        }
        updateModifierRefreshTimer()
        // Don't call super - we handle all key events
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            if isCapsLockKey {
                continue
            }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                resyncModifiers(
                    using: event,
                    fallbackFlags: fallbackFlags,
                    allowFallback: false,
                    removing: key.keyCode
                )
            } else {
                stopKeyRepeat(for: key.keyCode)
                resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyUp(keyEvent))
                }
            }
        }
        updateModifierRefreshTimer()
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            if isCapsLockKey {
                continue
            }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                resyncModifiers(
                    using: event,
                    fallbackFlags: fallbackFlags,
                    allowFallback: false,
                    removing: key.keyCode
                )
            } else {
                stopKeyRepeat(for: key.keyCode)
                resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true)
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) {
                    onInputEvent?(.keyUp(keyEvent))
                }
            }
        }
        updateModifierRefreshTimer()
    }

    public override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // pressesChanged is for force/altitude changes, not modifier state changes
        // We track modifier state via pressesBegan/pressesEnded instead
    }

    // MARK: - Key Repeat

    /// Start key repeat timer for a held key
    func startKeyRepeat(for press: UIPress) {
        guard let key = press.key else { return }
        let keyCode = key.keyCode

        // Cancel any existing timer for this key
        stopKeyRepeat(for: keyCode)

        // Store the press reference for generating repeat events
        heldKeyPresses[keyCode] = press

        // Schedule initial delay timer, then switch to repeat interval
        let initialTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInitialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }

            // Start repeating timer
            let repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.keyRepeatInterval, repeats: true) { [weak self] _ in
                self?.fireKeyRepeat(for: keyCode)
            }
            self.keyRepeatTimers[keyCode] = repeatTimer

            // Fire first repeat immediately after initial delay
            self.fireKeyRepeat(for: keyCode)
        }
        keyRepeatTimers[keyCode] = initialTimer
    }

    /// Stop key repeat timer for a key
    func stopKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        keyRepeatTimers[keyCode]?.invalidate()
        keyRepeatTimers.removeValue(forKey: keyCode)
        heldKeyPresses.removeValue(forKey: keyCode)
    }

    /// Fire a key repeat event
    func fireKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        guard let press = heldKeyPresses[keyCode],
              let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers, isRepeat: true) else { return }
        onInputEvent?(.keyDown(keyEvent))
    }

    /// Stop all active key repeat timers (call when view loses focus)
    func stopAllKeyRepeats() {
        for (_, timer) in keyRepeatTimers {
            timer.invalidate()
        }
        keyRepeatTimers.removeAll()
        heldKeyPresses.removeAll()
    }

    // MARK: - System Shortcut Interception

    /// Override keyCommands to intercept system shortcuts (CMD+W, CMD+Q, etc.)
    /// and forward them to the host instead of letting iOS handle them
    public override var keyCommands: [UIKeyCommand]? {
        let passthroughShortcuts: [(String, UIKeyModifierFlags)] = [
            ("w", .command),           // Close window
            ("q", .command),           // Quit
            (".", .command),           // Cancel
            ("h", .command),           // Hide
            ("m", .command),           // Minimize
            (",", .command),           // Settings
            ("n", .command),           // New
            ("o", .command),           // Open
            ("s", .command),           // Save
            ("p", .command),           // Print
            ("z", .command),           // Undo
            ("z", [.command, .shift]), // Redo
            ("a", .command),           // Select all
            ("c", .command),           // Copy
            ("x", .command),           // Cut
            ("v", .command),           // Paste
            ("f", .command),           // Find
            ("g", .command),           // Find next
            ("g", [.command, .shift]), // Find previous
            ("t", .command),           // New tab
            ("w", [.command, .shift]), // Close all
        ]

        return passthroughShortcuts.map { (key, modifiers) in
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: key,
                modifierFlags: modifiers
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc func handlePassthroughShortcut(_ command: UIKeyCommand) {
        // UIKeyCommand intercepts key events BEFORE pressesBegan is called
        // So we must manually send the character key events here
        guard let input = command.input else { return }

        let macKeyCode = Self.characterToMacKeyCode(input)

        // Build modifiers from the command's modifier flags merged with our tracked keyboard state.
        // Keep shortcuts stateless so key commands don't pin modifier state.
        let commandModifiers = MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        let eventModifiers = keyboardModifiers.union(commandModifiers)

        // Send keyDown for the character key
        let keyDownEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: eventModifiers
        )
        onInputEvent?(.keyDown(keyDownEvent))

        // Send keyUp immediately (shortcuts are instant, not held)
        let keyUpEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: eventModifiers
        )
        onInputEvent?(.keyUp(keyUpEvent))

        // Refresh hardware state to sync modifiers after shortcut handling.
        // iOS doesn't call pressesEnded for modifiers during UIKeyCommand interception.
#if canImport(GameController)
        refreshModifierStateFromHardware()
#endif
        updateModifierRefreshTimer()
    }

    /// Convert a character to macOS virtual key code
    /// Used by handlePassthroughShortcut to send key events for UIKeyCommand shortcuts
    static func characterToMacKeyCode(_ char: String) -> UInt16 {
        switch char.lowercased() {
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case "0": return 0x1D
        case ",": return 0x2B
        case ".": return 0x2F
        case "/": return 0x2C
        case ";": return 0x29
        case "'": return 0x27
        case "[": return 0x21
        case "]": return 0x1E
        case "\\": return 0x2A
        case "-": return 0x1B
        case "=": return 0x18
        case "`": return 0x32
        default: return 0x00  // Default to 'a' for unknown characters
        }
    }
}
#endif
