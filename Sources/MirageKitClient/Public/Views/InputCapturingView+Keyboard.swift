//
//  InputCapturingView+Keyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
    // MARK: - GCKeyboard Key Event Handling

    #if canImport(GameController)
    /// Handle a non-modifier key event from GCKeyboard.
    /// Only claims the event when modifiers are held — without modifiers, pressesBegan
    /// provides richer character data and is the better source.
    func handleGCKeyEvent(keyCode: GCKeyCode, isPressed: Bool) {
        // Handle key-up first so gcClaimedKeyCodes is cleaned up even when
        // modifiers have already been released by the time the key-up arrives.
        if !isPressed {
            guard gcClaimedKeyCodes.remove(keyCode) != nil else { return }
            guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }
            let macKeyCode = MirageKeyEvent.hidToMacKeyCode(hidUsage)
            let character = Self.characterToMacKeyCodeMap.first { $0.value == macKeyCode }?.key
            let keyEvent = MirageKeyEvent(
                keyCode: macKeyCode,
                characters: character,
                charactersIgnoringModifiers: character,
                modifiers: keyboardModifiers
            )
            onInputEvent?(.keyUp(keyEvent))
            return
        }

        // Only claim modifier+key combos; unmodified keys flow through pressesBegan
        guard !heldModifierKeys.isEmpty,
              let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue))
        else { return }

        let macKeyCode = MirageKeyEvent.hidToMacKeyCode(hidUsage)
        let character = Self.characterToMacKeyCodeMap.first { $0.value == macKeyCode }?.key

        gcClaimedKeyCodes.insert(keyCode)

        let keyEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: character,
            charactersIgnoringModifiers: character,
            modifiers: keyboardModifiers
        )
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(keyEvent))
    }
    #endif

    // MARK: - Keyboard Input (External Keyboard)

    private func modifierSnapshot(
        from event: UIPressesEvent?,
        fallbackFlags: UIKeyModifierFlags?,
        allowFallback: Bool
    )
    -> UIKeyModifierFlags? {
        if let flags = event?.modifierFlags { return flags }
        if allowFallback { return fallbackFlags }
        return nil
    }

    private func sanitizedModifierFlags(
        _ flags: UIKeyModifierFlags,
        removing keyCode: UIKeyboardHIDUsage?
    )
    -> UIKeyModifierFlags {
        guard let keyCode else { return flags }
        var sanitized = flags
        switch keyCode {
        case .keyboardLeftShift,
             .keyboardRightShift:
            sanitized.remove(.shift)
        case .keyboardLeftControl,
             .keyboardRightControl:
            sanitized.remove(.control)
        case .keyboardLeftAlt,
             .keyboardRightAlt:
            sanitized.remove(.alternate)
        case .keyboardLeftGUI,
             .keyboardRightGUI:
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
        if heldModifierKeys.isEmpty { stopModifierRefresh() } else {
            startModifierRefreshIfNeeded()
        }
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        updateHardwareKeyboardPresence(true)
        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            // Escape without modifiers clears any stuck modifier state as a recovery mechanism
            if key.keyCode == .keyboardEscape {
                let flags = modifierSnapshot(from: event, fallbackFlags: fallbackFlags, allowFallback: true) ?? []
                if flags.isEmpty { resetAllModifiers() }
            }

            if isCapsLockKey {
                capsLockEnabled.toggle()
                sendModifierStateIfNeeded(force: true)
                continue
            }

            if let modifierFlags = modifierSnapshot(from: event, fallbackFlags: fallbackFlags, allowFallback: true) { updateCapsLockState(from: modifierFlags) }
            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.insert(key.keyCode)
                if allowFallback { resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true) } else {
                    sendModifierStateIfNeeded(force: true)
                }
            } else {
                #if canImport(GameController)
                // Skip if GCKeyboard already claimed this key (modifier+key combo)
                if gcClaimedKeyCodes.contains(GCKeyCode(rawValue: key.keyCode.rawValue)) { continue }
                #endif
                if allowFallback { resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true) }
                if !keyboardModifiers.contains(.command) { startKeyRepeat(for: press) }
                hideCursorForTypingUntilPointerMovement()
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) { onInputEvent?(.keyDown(keyEvent)) }
            }
        }
        updateModifierRefreshTimer()
        // Don't call super - we handle all key events
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            if isCapsLockKey { continue }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                if allowFallback {
                    resyncModifiers(
                        using: event,
                        fallbackFlags: fallbackFlags,
                        allowFallback: false,
                        removing: key.keyCode
                    )
                } else {
                    sendModifierStateIfNeeded(force: true)
                }
            } else {
                #if canImport(GameController)
                // Skip if GCKeyboard already claimed this key (modifier+key combo).
                // Use remove so cleanup happens from both paths.
                let gcKey = GCKeyCode(rawValue: key.keyCode.rawValue)
                if gcClaimedKeyCodes.remove(gcKey) != nil { continue }
                #endif
                stopKeyRepeat(for: key.keyCode)
                if allowFallback { resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true) }
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) { onInputEvent?(.keyUp(keyEvent)) }
            }
        }
        updateModifierRefreshTimer()
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags

            if isCapsLockKey { continue }

            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.remove(key.keyCode)
                if allowFallback {
                    resyncModifiers(
                        using: event,
                        fallbackFlags: fallbackFlags,
                        allowFallback: false,
                        removing: key.keyCode
                    )
                } else {
                    sendModifierStateIfNeeded(force: true)
                }
            } else {
                #if canImport(GameController)
                // Skip if GCKeyboard already claimed this key (modifier+key combo).
                // Use remove so cleanup happens from both paths.
                let gcKey = GCKeyCode(rawValue: key.keyCode.rawValue)
                if gcClaimedKeyCodes.remove(gcKey) != nil { continue }
                #endif
                stopKeyRepeat(for: key.keyCode)
                if allowFallback { resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true) }
                if let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers) { onInputEvent?(.keyUp(keyEvent)) }
            }
        }
        updateModifierRefreshTimer()
    }

    override public func pressesChanged(_: Set<UIPress>, with _: UIPressesEvent?) {
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
        let initialTimer = Timer
            .scheduledTimer(withTimeInterval: Self.keyRepeatInitialDelay, repeats: false) { [weak self] _ in
                guard let self else { return }

                // Start repeating timer
                let repeatTimer = Timer
                    .scheduledTimer(withTimeInterval: Self.keyRepeatInterval, repeats: true) { [weak self] _ in
                        self?.fireKeyRepeat(for: keyCode)
                    }
                keyRepeatTimers[keyCode] = repeatTimer

                // Fire first repeat immediately after initial delay
                fireKeyRepeat(for: keyCode)
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
        refreshModifiersForInput()
        if keyboardModifiers.contains(.command) {
            stopKeyRepeat(for: keyCode)
            return
        }
        guard let press = heldKeyPresses[keyCode],
              let keyEvent = MirageKeyEvent(press: press, modifiers: keyboardModifiers, isRepeat: true) else {
            return
        }
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(keyEvent))
    }

    /// Stop all active key repeat timers (call when view loses focus)
    func stopAllKeyRepeats() {
        for (_, timer) in keyRepeatTimers {
            timer.invalidate()
        }
        keyRepeatTimers.removeAll()
        heldKeyPresses.removeAll()
        stopPassthroughShortcutRepeat(sendKeyUp: true)
    }

    // MARK: - Intercepted Shortcut Repeat

    private func shouldRepeatPassthroughShortcut(
        input: String,
        modifiers: MirageModifierFlags
    ) -> Bool {
        guard input.lowercased() == "z" else { return false }
        var normalized = modifiers
        normalized.remove(.capsLock)
        guard normalized.contains(.command) else { return false }
        let allowedModifiers: MirageModifierFlags = [.command, .shift]
        return normalized.subtracting(allowedModifiers).isEmpty
    }

    private func sendPassthroughShortcutKeyDown(
        keyCode: UInt16,
        input: String,
        modifiers: MirageModifierFlags,
        isRepeat: Bool
    ) {
        let keyDownEvent = MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(keyDownEvent))
    }

    private func sendPassthroughShortcutKeyUp(
        keyCode: UInt16,
        input: String,
        modifiers: MirageModifierFlags
    ) {
        let keyUpEvent = MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: modifiers
        )
        onInputEvent?(.keyUp(keyUpEvent))
    }

    @discardableResult
    private func startPassthroughShortcutRepeatIfNeeded(
        input: String,
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> Bool {
        guard shouldRepeatPassthroughShortcut(input: input, modifiers: modifiers) else { return false }

        if let existing = passthroughShortcutRepeatState {
            if existing.keyCode == keyCode,
               existing.input == input,
               existing.modifiers == modifiers {
                return true
            }
            stopPassthroughShortcutRepeat(sendKeyUp: true)
        }

        let requiresShift = modifiers.contains(.shift)
        sendPassthroughShortcutKeyDown(
            keyCode: keyCode,
            input: input,
            modifiers: modifiers,
            isRepeat: false
        )

        guard isPassthroughShortcutHeld(requiresShift: requiresShift) else {
            sendPassthroughShortcutKeyUp(
                keyCode: keyCode,
                input: input,
                modifiers: modifiers
            )
            return true
        }

        passthroughShortcutRepeatState = PassthroughShortcutRepeatState(
            keyCode: keyCode,
            input: input,
            modifiers: modifiers,
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

    private func tickPassthroughShortcutRepeat() {
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

        sendPassthroughShortcutKeyDown(
            keyCode: state.keyCode,
            input: state.input,
            modifiers: state.modifiers,
            isRepeat: true
        )
        state.nextRepeatDeadline = now + Self.keyRepeatInterval
        passthroughShortcutRepeatState = state
    }

    private func stopPassthroughShortcutRepeat(sendKeyUp: Bool) {
        if sendKeyUp, let state = passthroughShortcutRepeatState {
            sendPassthroughShortcutKeyUp(
                keyCode: state.keyCode,
                input: state.input,
                modifiers: state.modifiers
            )
        }

        passthroughShortcutRepeatState = nil
        passthroughShortcutRepeatTimer?.invalidate()
        passthroughShortcutRepeatTimer = nil
    }

    private func isPassthroughShortcutHeld(requiresShift: Bool) -> Bool {
        #if canImport(GameController)
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        let commandHeld = keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true
            || keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true
        let zHeld = keyboardInput.button(forKeyCode: .keyZ)?.isPressed == true
        guard commandHeld, zHeld else { return false }
        if requiresShift {
            let shiftHeld = keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true
                || keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true
            return shiftHeld
        }
        return true
        #else
        _ = requiresShift
        return false
        #endif
    }

    // MARK: - System Shortcut Interception

    /// Override keyCommands to suppress iOS system-level actions (Stage Manager close,
    /// quit, hide, minimize, settings) that would otherwise steal focus or dismiss the app.
    /// When GCKeyboard is available, it handles the actual key forwarding — these commands
    /// only need to exist to block iOS from acting on them. Without GCKeyboard, the
    /// handler falls back to sending key events directly.
    override public var keyCommands: [UIKeyCommand]? {
        let passthroughShortcuts: [(String, UIKeyModifierFlags)] = [
            ("w", .command), // Stage Manager window close
            ("q", .command), // Quit
            ("h", .command), // Hide
            ("m", .command), // Minimize
            (",", .command), // Settings
            ("w", [.command, .shift]), // Close all
            ("z", .command), // Undo (needed for key repeat)
            ("z", [.command, .shift]), // Redo (needed for key repeat)
            ("b", .command), // Bold (system text formatting)
            ("i", .command), // Italic (system text formatting)
            ("u", .command), // Underline (system text formatting)
        ]

        return passthroughShortcuts.map { key, modifiers in
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: key,
                modifierFlags: modifiers
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc
    func handlePassthroughShortcut(_ command: UIKeyCommand) {
        guard let input = command.input else { return }

        refreshModifiersForInput()

        #if canImport(GameController)
        // When GCKeyboard is available, it already forwarded the key event.
        // We only need to handle undo/redo repeat and keep modifiers synced.
        if GCKeyboard.coalesced != nil {
            let macKeyCode = Self.characterToMacKeyCode(input)
            let commandModifiers = MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
            let eventModifiers = keyboardModifiers.union(commandModifiers)
            startPassthroughShortcutRepeatIfNeeded(
                input: input,
                keyCode: macKeyCode,
                modifiers: eventModifiers
            )
            refreshModifiersForInput()
            updateModifierRefreshTimer()
            return
        }
        #endif

        // Fallback: no GCKeyboard — send key events directly
        let macKeyCode = Self.characterToMacKeyCode(input)
        let commandModifiers = MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        let eventModifiers = keyboardModifiers.union(commandModifiers)

        if !startPassthroughShortcutRepeatIfNeeded(
            input: input,
            keyCode: macKeyCode,
            modifiers: eventModifiers
        ) {
            sendPassthroughShortcutKeyDown(
                keyCode: macKeyCode,
                input: input,
                modifiers: eventModifiers,
                isRepeat: false
            )
            sendPassthroughShortcutKeyUp(
                keyCode: macKeyCode,
                input: input,
                modifiers: eventModifiers
            )
        }

        refreshModifiersForInput()
        updateModifierRefreshTimer()
    }

    /// Convert a character to macOS virtual key code
    /// Used by handlePassthroughShortcut to send key events for UIKeyCommand shortcuts
    static let characterToMacKeyCodeMap: [String: UInt16] = [
        "a": 0x00,
        "b": 0x0B,
        "c": 0x08,
        "d": 0x02,
        "e": 0x0E,
        "f": 0x03,
        "g": 0x05,
        "h": 0x04,
        "i": 0x22,
        "j": 0x26,
        "k": 0x28,
        "l": 0x25,
        "m": 0x2E,
        "n": 0x2D,
        "o": 0x1F,
        "p": 0x23,
        "q": 0x0C,
        "r": 0x0F,
        "s": 0x01,
        "t": 0x11,
        "u": 0x20,
        "v": 0x09,
        "w": 0x0D,
        "x": 0x07,
        "y": 0x10,
        "z": 0x06,
        "1": 0x12,
        "2": 0x13,
        "3": 0x14,
        "4": 0x15,
        "5": 0x17,
        "6": 0x16,
        "7": 0x1A,
        "8": 0x1C,
        "9": 0x19,
        "0": 0x1D,
        ",": 0x2B,
        ".": 0x2F,
        "/": 0x2C,
        ";": 0x29,
        "'": 0x27,
        "[": 0x21,
        "]": 0x1E,
        "\\": 0x2A,
        "-": 0x1B,
        "=": 0x18,
        "`": 0x32,
        " ": 0x31,
        "\t": 0x30,
        "\n": 0x24,
    ]

    static func characterToMacKeyCode(_ char: String) -> UInt16 {
        // Default to 'a' for unknown characters
        characterToMacKeyCodeMap[char.lowercased()] ?? 0x00
    }

    static func characterToMacKeyCodeIfKnown(_ char: String) -> UInt16? {
        characterToMacKeyCodeMap[char.lowercased()]
    }
}
#endif
