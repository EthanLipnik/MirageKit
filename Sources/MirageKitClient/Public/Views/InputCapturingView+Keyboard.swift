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
            guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }
            guard gcClaimedKeyCodes.remove(keyCode) != nil else { return }
            if passthroughClaimedKeyCodes.remove(hidUsage) != nil { return }
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
        let eventModifiers = keyboardModifiers
        if let shortcut = MirageInterceptedShortcutPolicy.shortcut(
            keyCode: macKeyCode,
            modifiers: eventModifiers
        ) {
            gcClaimedKeyCodes.insert(keyCode)
            passthroughClaimedKeyCodes.insert(hidUsage)
            performPassthroughShortcut(shortcut, source: .hardwareKey)
            return
        }
        let character = Self.characterToMacKeyCodeMap.first { $0.value == macKeyCode }?.key

        gcClaimedKeyCodes.insert(keyCode)

        let keyEvent = MirageKeyEvent(
            keyCode: macKeyCode,
            characters: character,
            charactersIgnoringModifiers: character,
            modifiers: eventModifiers
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

    private static func uiKeyModifierFlags(
        from modifiers: MirageModifierFlags
    ) -> UIKeyModifierFlags {
        var result: UIKeyModifierFlags = []
        if modifiers.contains(.capsLock) { result.insert(.alphaShift) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.alternate) }
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.numericPad) { result.insert(.numericPad) }
        return result
    }

    private func interceptedShortcut(
        for keyCode: UIKeyboardHIDUsage,
        modifierFlags: UIKeyModifierFlags?
    ) -> MirageInterceptedShortcut? {
        let fallbackModifiers = modifierFlags.map(MirageModifierFlags.init(uiKeyModifierFlags:))
        let eventModifiers = fallbackModifiers ?? keyboardModifiers
        let macKeyCode = MirageKeyEvent.hidToMacKeyCode(keyCode)
        return MirageInterceptedShortcutPolicy.shortcut(
            keyCode: macKeyCode,
            modifiers: eventModifiers
        )
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
                if flags.isEmpty, requestCursorLockEscapeIfNeeded() {
                    resetAllModifiers()
                    suppressEscapeKeyUpForCursorUnlock = true
                    continue
                }
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
                if passthroughClaimedKeyCodes.contains(key.keyCode) { continue }
                // Skip if GCKeyboard already claimed this key (modifier+key combo)
                if gcClaimedKeyCodes.contains(GCKeyCode(rawValue: key.keyCode.rawValue)) { continue }
                #endif
                if let shortcut = interceptedShortcut(
                    for: key.keyCode,
                    modifierFlags: event?.modifierFlags ?? fallbackFlags
                ) {
                    if allowFallback {
                        resyncModifiers(
                            using: event,
                            fallbackFlags: fallbackFlags,
                            allowFallback: true
                        )
                    }
                    performPassthroughShortcut(shortcut, source: .hardwareKey)
                    continue
                }
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

            if key.keyCode == .keyboardEscape, suppressEscapeKeyUpForCursorUnlock {
                suppressEscapeKeyUpForCursorUnlock = false
                continue
            }

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
                let shortcut = interceptedShortcut(
                    for: key.keyCode,
                    modifierFlags: event?.modifierFlags ?? fallbackFlags
                )
                #if canImport(GameController)
                if passthroughClaimedKeyCodes.remove(key.keyCode) != nil {
                    gcClaimedKeyCodes.remove(GCKeyCode(rawValue: key.keyCode.rawValue))
                    continue
                }
                // Skip if GCKeyboard already claimed this key (modifier+key combo).
                // Use remove so cleanup happens from both paths.
                let gcKey = GCKeyCode(rawValue: key.keyCode.rawValue)
                if gcClaimedKeyCodes.remove(gcKey) != nil { continue }
                #endif
                if shortcut != nil { continue }
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

            if key.keyCode == .keyboardEscape, suppressEscapeKeyUpForCursorUnlock {
                suppressEscapeKeyUpForCursorUnlock = false
                continue
            }

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
                let shortcut = interceptedShortcut(
                    for: key.keyCode,
                    modifierFlags: event?.modifierFlags ?? fallbackFlags
                )
                #if canImport(GameController)
                if passthroughClaimedKeyCodes.remove(key.keyCode) != nil {
                    gcClaimedKeyCodes.remove(GCKeyCode(rawValue: key.keyCode.rawValue))
                    continue
                }
                // Skip if GCKeyboard already claimed this key (modifier+key combo).
                // Use remove so cleanup happens from both paths.
                let gcKey = GCKeyCode(rawValue: key.keyCode.rawValue)
                if gcClaimedKeyCodes.remove(gcKey) != nil { continue }
                #endif
                if shortcut != nil { continue }
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
        lastPassthroughShortcutDispatch = nil
    }

    // MARK: - Intercepted Shortcut Repeat

    private func shouldRepeatPassthroughShortcut(
        shortcut: MirageInterceptedShortcut
    ) -> Bool {
        shortcut.allowsRepeat
    }

    private func sendPassthroughShortcutKeyDown(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags,
        isRepeat: Bool
    ) {
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(shortcut.keyDownEvent(baseModifiers: baseModifiers, isRepeat: isRepeat)))
    }

    private func sendPassthroughShortcutKeyUp(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags
    ) {
        onInputEvent?(.keyUp(shortcut.keyUpEvent(baseModifiers: baseModifiers)))
    }

    @discardableResult
    private func startPassthroughShortcutRepeatIfNeeded(
        shortcut: MirageInterceptedShortcut,
        baseModifiers: MirageModifierFlags
    ) -> Bool {
        guard shouldRepeatPassthroughShortcut(shortcut: shortcut) else { return false }
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

        let shortcut = MirageInterceptedShortcut(
            input: state.input,
            keyCode: state.keyCode,
            modifiers: MirageInterceptedShortcutPolicy.normalizedShortcutModifiers(state.modifiers),
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

    private func stopPassthroughShortcutRepeat(sendKeyUp: Bool) {
        if sendKeyUp, let state = passthroughShortcutRepeatState {
            let shortcut = MirageInterceptedShortcut(
                input: state.input,
                keyCode: state.keyCode,
                modifiers: MirageInterceptedShortcutPolicy.normalizedShortcutModifiers(state.modifiers),
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

    private func editActionShortcut(
        for action: Selector
    ) -> MirageInterceptedShortcut? {
        MirageInterceptedShortcutPolicy.shortcut(
            actionName: NSStringFromSelector(action)
        )
    }

    private func shouldSuppressPassthroughShortcutDispatch(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) -> Bool {
        guard let lastDispatch = lastPassthroughShortcutDispatch else { return false }
        guard lastDispatch.shortcut == shortcut else { return false }
        guard lastDispatch.source != source else { return false }
        return CFAbsoluteTimeGetCurrent() - lastDispatch.timestamp
            <= Self.passthroughShortcutDuplicateSuppressionWindow
    }

    private func notePassthroughShortcutDispatch(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) {
        lastPassthroughShortcutDispatch = PassthroughShortcutDispatch(
            shortcut: shortcut,
            source: source,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    private func performPassthroughShortcut(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) {
        guard onInputEvent != nil else { return }
        guard !shouldSuppressPassthroughShortcutDispatch(shortcut, source: source) else {
            return
        }
        notePassthroughShortcutDispatch(shortcut, source: source)
        refreshModifiersForInput()

        if !startPassthroughShortcutRepeatIfNeeded(
            shortcut: shortcut,
            baseModifiers: keyboardModifiers
        ) {
            sendPassthroughShortcutKeyDown(
                shortcut: shortcut,
                baseModifiers: keyboardModifiers,
                isRepeat: false
            )
            sendPassthroughShortcutKeyUp(
                shortcut: shortcut,
                baseModifiers: keyboardModifiers
            )
        }

        refreshModifiersForInput()
        updateModifierRefreshTimer()
    }

    /// Override keyCommands to claim iPadOS system shortcuts that would otherwise be
    /// handled locally instead of reaching the remote host.
    override public var keyCommands: [UIKeyCommand]? {
        MirageInterceptedShortcutPolicy.shortcuts.map { shortcut in
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: shortcut.input,
                modifierFlags: Self.uiKeyModifierFlags(from: shortcut.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override public func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if onInputEvent != nil, editActionShortcut(for: action) != nil {
            return self
        }
        return super.target(forAction: action, withSender: sender)
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if editActionShortcut(for: action) != nil {
            return onInputEvent != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc
    func handlePassthroughShortcut(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        guard let shortcut = MirageInterceptedShortcutPolicy.shortcut(
            input: input,
            modifiers: MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        ) else {
            return
        }

        performPassthroughShortcut(shortcut, source: .keyCommand)
    }

    override public func toggleBoldface(_: Any?) {
        guard let shortcut = editActionShortcut(for: #selector(toggleBoldface(_:))) else { return }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    @objc
    public func undo(_: Any?) {
        guard let shortcut = editActionShortcut(for: #selector(undo(_:))) else { return }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    @objc
    public func redo(_: Any?) {
        guard let shortcut = editActionShortcut(for: #selector(redo(_:))) else { return }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    override public func toggleItalics(_: Any?) {
        guard let shortcut = editActionShortcut(for: #selector(toggleItalics(_:))) else { return }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    override public func toggleUnderline(_: Any?) {
        guard let shortcut = editActionShortcut(for: #selector(toggleUnderline(_:))) else { return }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    /// Convert a character to macOS virtual key code
    /// Used by handlePassthroughShortcut to send key events for UIKeyCommand shortcuts
    static var characterToMacKeyCodeMap: [String: UInt16] {
        MirageClientKeyEventBuilder.characterToMacKeyCodeMap
    }

    static func characterToMacKeyCode(_ char: String) -> UInt16 {
        MirageClientKeyEventBuilder.characterToMacKeyCode(char)
    }

    static func characterToMacKeyCodeIfKnown(_ char: String) -> UInt16? {
        MirageClientKeyEventBuilder.characterToMacKeyCodeIfKnown(char)
    }
}
#endif
