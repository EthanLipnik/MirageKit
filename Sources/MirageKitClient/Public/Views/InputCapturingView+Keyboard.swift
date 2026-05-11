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

private struct ShortcutCommandIdentity: Hashable {
    let input: String
    let modifiers: MirageModifierFlags
}

#if canImport(GameController)
enum GCKeyboardKeyRoutingDecision: Equatable {
    case ignore
    case action
    case clientShortcut
    case passthroughShortcut
    case forwardKey
}
#endif

extension InputCapturingView {
    // MARK: - GCKeyboard Key Event Handling

    #if canImport(GameController)
    nonisolated static func gcKeyboardKeyRoutingDecision(
        hasHeldModifiers: Bool,
        hasAction: Bool,
        hasClientShortcut: Bool,
        hasPassthroughShortcut: Bool
    ) -> GCKeyboardKeyRoutingDecision {
        guard hasHeldModifiers else { return .ignore }
        if hasAction { return .action }
        if hasClientShortcut { return .clientShortcut }
        if hasPassthroughShortcut { return .passthroughShortcut }
        return .forwardKey
    }

    nonisolated static func shouldClaimGCForwardKey(modifiers: MirageModifierFlags) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }

    nonisolated static func shouldClaimGCForwardKey(
        macKeyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> Bool {
        if shouldClaimGCForwardKey(modifiers: modifiers) {
            return true
        }
        return modifiers.contains(.option) && macKeyCode == 0x31
    }

    nonisolated static func shouldRecoverFirstResponderForGCShortcutModifiers(
        modifiers: MirageModifierFlags
    ) -> Bool {
        shouldClaimGCForwardKey(modifiers: modifiers)
    }

    nonisolated static func shouldRecoverFirstResponderForGCForwardKey(
        isPressed: Bool,
        modifiers: MirageModifierFlags
    ) -> Bool {
        isPressed && shouldRecoverFirstResponderForGCShortcutModifiers(modifiers: modifiers)
    }

    nonisolated static func shouldRecoverFirstResponderForGCKey(
        isPressed: Bool,
        macKeyCode: UInt16,
        modifiers: MirageModifierFlags,
        hasAction: Bool,
        hasClientShortcut: Bool,
        hasPassthroughShortcut: Bool
    ) -> Bool {
        guard isPressed else { return false }
        if hasAction || hasClientShortcut || hasPassthroughShortcut {
            return true
        }
        return shouldClaimGCForwardKey(macKeyCode: macKeyCode, modifiers: modifiers)
    }

    private func gcKeyboardKeyEvent(
        hidUsage: UIKeyboardHIDUsage,
        modifiers: MirageModifierFlags
    ) -> MirageKeyEvent {
        let macKeyCode = MirageKeyEvent.hidToMacKeyCode(hidUsage)
        let character = Self.characterToMacKeyCodeMap.first { $0.value == macKeyCode }?.key
        return MirageKeyEvent(
            keyCode: macKeyCode,
            characters: character,
            charactersIgnoringModifiers: character,
            modifiers: modifiers
        )
    }

    /// Handle a non-modifier key event from GCKeyboard.
    /// Only claims the event when modifiers are held — without modifiers, pressesBegan
    /// provides richer character data and is the better source.
    func handleGCKeyEvent(keyCode: GCKeyCode, isPressed: Bool) {
        guard inputCaptureEnabled else {
            if !isPressed, let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) {
                gcClaimedKeyCodes.remove(keyCode)
                clientShortcutClaimedKeyCodes.remove(hidUsage)
                passthroughClaimedKeyCodes.remove(hidUsage)
            }
            return
        }

        // Handle key-up first so gcClaimedKeyCodes is cleaned up even when
        // modifiers have already been released by the time the key-up arrives.
        if !isPressed {
            guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }
            guard gcClaimedKeyCodes.remove(keyCode) != nil else { return }
            if clientShortcutClaimedKeyCodes.remove(hidUsage) != nil { return }
            if passthroughClaimedKeyCodes.remove(hidUsage) != nil { return }
            let keyEvent = gcKeyboardKeyEvent(hidUsage: hidUsage, modifiers: keyboardModifiers)
            onInputEvent?(.keyUp(keyEvent))
            return
        }

        guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return }

        let eventModifiers = keyboardModifiers
        let macKeyCode = MirageKeyEvent.hidToMacKeyCode(hidUsage)
        let decision = Self.gcKeyboardKeyRoutingDecision(
            hasHeldModifiers: !heldModifierKeys.isEmpty,
            hasAction: matchingAction(keyCode: macKeyCode, modifiers: eventModifiers) != nil,
            hasClientShortcut: clientShortcut(
                keyCode: macKeyCode,
                modifiers: eventModifiers
            ) != nil,
            hasPassthroughShortcut: MirageInterceptedShortcutPolicy.shortcut(
                keyCode: macKeyCode,
                modifiers: eventModifiers
            ) != nil
        )

        switch decision {
        case .ignore:
            return

        case .action:
            gcClaimedKeyCodes.insert(keyCode)
            clientShortcutClaimedKeyCodes.insert(hidUsage)
            if let action = matchingAction(keyCode: macKeyCode, modifiers: eventModifiers) {
                performAction(action, source: .hardwareKey)
            }

        case .clientShortcut:
            gcClaimedKeyCodes.insert(keyCode)
            clientShortcutClaimedKeyCodes.insert(hidUsage)
            if let shortcut = clientShortcut(
                keyCode: macKeyCode,
                modifiers: eventModifiers
            ) {
                performClientShortcut(shortcut, source: .hardwareKey)
            }

        case .passthroughShortcut:
            gcClaimedKeyCodes.insert(keyCode)
            passthroughClaimedKeyCodes.insert(hidUsage)
            if let shortcut = MirageInterceptedShortcutPolicy.shortcut(
                keyCode: macKeyCode,
                modifiers: eventModifiers
            ) {
                performPassthroughShortcut(shortcut, source: .hardwareKey)
            }

        case .forwardKey:
            guard Self.shouldClaimGCForwardKey(macKeyCode: macKeyCode, modifiers: eventModifiers) else {
                return
            }
            gcClaimedKeyCodes.insert(keyCode)
            hideCursorForTypingUntilPointerMovement()
            onInputEvent?(.keyDown(gcKeyboardKeyEvent(hidUsage: hidUsage, modifiers: eventModifiers)))
        }
    }

    func recoverFirstResponderForGCKeyIfNeeded(keyCode: GCKeyCode, isPressed: Bool) -> Bool {
        guard inputCaptureEnabled else { return false }
        guard !isFirstResponder else { return true }
        guard window?.windowScene?.activationState == .foregroundActive else { return false }
        guard refreshModifierStateFromHardware() else { return false }
        guard let hidUsage = UIKeyboardHIDUsage(rawValue: Int(keyCode.rawValue)) else { return false }
        let macKeyCode = MirageKeyEvent.hidToMacKeyCode(hidUsage)
        let eventModifiers = keyboardModifiers
        guard Self.shouldRecoverFirstResponderForGCKey(
            isPressed: isPressed,
            macKeyCode: macKeyCode,
            modifiers: eventModifiers,
            hasAction: matchingAction(keyCode: macKeyCode, modifiers: eventModifiers) != nil,
            hasClientShortcut: clientShortcut(keyCode: macKeyCode, modifiers: eventModifiers) != nil,
            hasPassthroughShortcut: MirageInterceptedShortcutPolicy.shortcut(
                keyCode: macKeyCode,
                modifiers: eventModifiers
            ) != nil
        ) else {
            return false
        }
        guard responderRecoveryTarget() == .captureView else { return false }
        return attemptResponderRecovery(for: .captureView)
    }

    func recoverFirstResponderForGCShortcutModifierIfNeeded() -> Bool {
        guard inputCaptureEnabled else { return false }
        guard !isFirstResponder else { return true }
        guard window?.windowScene?.activationState == .foregroundActive else { return false }
        guard Self.shouldRecoverFirstResponderForGCShortcutModifiers(
            modifiers: keyboardModifiers
        ) else {
            return false
        }
        guard responderRecoveryTarget() == .captureView else { return false }
        return attemptResponderRecovery(for: .captureView)
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

    private static func uiKeyShortcutModifierFlags(
        from modifiers: MirageModifierFlags
    ) -> UIKeyModifierFlags {
        uiKeyModifierFlags(from: modifiers.normalizedForShortcutMatching)
    }

    static func resolvedHardwareKeyModifiers(
        reportedModifiers: MirageModifierFlags?,
        trackedModifiers: MirageModifierFlags
    ) -> MirageModifierFlags {
        guard let reportedModifiers else { return trackedModifiers }
        return trackedModifiers.union(reportedModifiers)
    }

    private func resolvedHardwareKeyModifiers(
        from event: UIPressesEvent?,
        fallbackFlags: UIKeyModifierFlags?
    ) -> MirageModifierFlags {
        let reportedModifiers = modifierSnapshot(
            from: event,
            fallbackFlags: fallbackFlags,
            allowFallback: true
        )
        .map(MirageModifierFlags.init(uiKeyModifierFlags:))

        return Self.resolvedHardwareKeyModifiers(
            reportedModifiers: reportedModifiers,
            trackedModifiers: keyboardModifiers
        )
    }

    private func clientShortcut(
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> MirageClientShortcut? {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return clientShortcuts.first { shortcut in
            shortcut.keyCode == keyCode &&
                shortcut.modifiers.normalizedForShortcutMatching == normalizedModifiers
        }
    }

    private func clientShortcut(
        for interceptedShortcut: MirageInterceptedShortcut
    ) -> MirageClientShortcut? {
        clientShortcut(
            keyCode: interceptedShortcut.keyCode,
            modifiers: interceptedShortcut.modifiers
        )
    }

    // MARK: - Unified Action Matching

    private func matchingAction(
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> MirageAction? {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return actions.first { action in
            guard action.isEnabled else { return false }
            guard let binding = action.shortcut else { return false }
            return binding.keyCode == keyCode &&
                binding.modifiers.normalizedForShortcutMatching == normalizedModifiers
        }
    }

    private func performAction(
        _ action: MirageAction,
        source: ClientShortcutDispatchSource
    ) {
        guard onActionTriggered != nil else { return }
        // Reuse the same duplicate suppression logic via the shortcut binding
        if let binding = action.shortcut {
            let asClientShortcut = MirageClientShortcut(binding)
            guard !shouldSuppressClientShortcutDispatch(asClientShortcut, source: source) else { return }
            noteClientShortcutDispatch(asClientShortcut, source: source)
        }
        onActionTriggered?(action)
    }

    private func keyCommandInput(
        for shortcut: MirageClientShortcut
    ) -> String? {
        switch shortcut.keyCode {
        case 0x24:
            "\n"
        case 0x30:
            "\t"
        case 0x31:
            " "
        case 0x33:
            UIKeyCommand.inputDelete
        case 0x35:
            UIKeyCommand.inputEscape
        case 0x7B:
            UIKeyCommand.inputLeftArrow
        case 0x7C:
            UIKeyCommand.inputRightArrow
        case 0x7D:
            UIKeyCommand.inputDownArrow
        case 0x7E:
            UIKeyCommand.inputUpArrow
        default:
            Self.characterToMacKeyCodeMap.first { $0.value == shortcut.keyCode }?.key
        }
    }

    func shouldHandleResponderAction(_ action: Selector) -> Bool {
        guard inputCaptureEnabled else { return false }
        guard let shortcut = editActionShortcut(for: action) else { return false }
        if clientShortcut(for: shortcut) != nil {
            return onClientShortcut != nil
        }
        return onInputEvent != nil
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputCaptureEnabled else {
            super.pressesBegan(presses, with: event)
            return
        }

        updateHardwareKeyboardPresence(true)
        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags
            let resolvedModifiers = resolvedHardwareKeyModifiers(
                from: event,
                fallbackFlags: fallbackFlags
            )
            let normalizedResolvedShortcutModifiers = resolvedModifiers.normalizedForShortcutMatching

            // Escape without modifiers clears any stuck modifier state as a recovery mechanism
            if key.keyCode == .keyboardEscape {
                if normalizedResolvedShortcutModifiers.isEmpty, requestCursorLockEscapeIfNeeded() {
                    resetAllModifiers()
                    suppressEscapeKeyUpForCursorUnlock = true
                    continue
                }
                if normalizedResolvedShortcutModifiers.isEmpty { resetAllModifiers() }
            }

            if isCapsLockKey {
                capsLockEnabled.toggle()
                sendModifierStateIfNeeded(force: true)
                continue
            }

            updateCapsLockState(from: Self.uiKeyModifierFlags(from: resolvedModifiers))
            let isModifier = Self.modifierKeyMap[key.keyCode] != nil

            if isModifier {
                heldModifierKeys.insert(key.keyCode)
                if allowFallback { resyncModifiers(using: event, fallbackFlags: fallbackFlags, allowFallback: true) } else {
                    sendModifierStateIfNeeded(force: true)
                }
            } else {
                #if canImport(GameController)
                if clientShortcutClaimedKeyCodes.contains(key.keyCode) { continue }
                if passthroughClaimedKeyCodes.contains(key.keyCode) { continue }
                // Skip if GCKeyboard already claimed this key (modifier+key combo)
                if gcClaimedKeyCodes.contains(GCKeyCode(rawValue: key.keyCode.rawValue)) { continue }
                #endif
                let macKeyCode = MirageKeyEvent.hidToMacKeyCode(key.keyCode)
                if let action = matchingAction(
                    keyCode: macKeyCode,
                    modifiers: resolvedModifiers
                ) {
                    #if canImport(GameController)
                    clientShortcutClaimedKeyCodes.insert(key.keyCode)
                    #endif
                    if allowFallback {
                        resyncModifiers(
                            using: event,
                            fallbackFlags: fallbackFlags,
                            allowFallback: true
                        )
                    }
                    performAction(action, source: .hardwareKey)
                    continue
                }
                if let shortcut = clientShortcut(
                    keyCode: macKeyCode,
                    modifiers: resolvedModifiers
                ) {
                    #if canImport(GameController)
                    clientShortcutClaimedKeyCodes.insert(key.keyCode)
                    #endif
                    if allowFallback {
                        resyncModifiers(
                            using: event,
                            fallbackFlags: fallbackFlags,
                            allowFallback: true
                        )
                    }
                    performClientShortcut(shortcut, source: .hardwareKey)
                    continue
                }
                if let shortcut = MirageInterceptedShortcutPolicy.shortcut(
                    keyCode: macKeyCode,
                    modifiers: resolvedModifiers
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
                if !resolvedModifiers.contains(.command) { startKeyRepeat(for: press) }
                hideCursorForTypingUntilPointerMovement()
                onInputEvent?(.keyDown(hardwareKeyEvent(for: press, modifiers: resolvedModifiers)))
            }
        }
        updateModifierRefreshTimer()
        // Don't call super - we handle all key events
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputCaptureEnabled else {
            super.pressesEnded(presses, with: event)
            return
        }

        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags
            let resolvedModifiers = resolvedHardwareKeyModifiers(
                from: event,
                fallbackFlags: fallbackFlags
            )

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
                let shortcut = MirageInterceptedShortcutPolicy.shortcut(
                    keyCode: MirageKeyEvent.hidToMacKeyCode(key.keyCode),
                    modifiers: resolvedModifiers
                )
                #if canImport(GameController)
                if clientShortcutClaimedKeyCodes.remove(key.keyCode) != nil {
                    gcClaimedKeyCodes.remove(GCKeyCode(rawValue: key.keyCode.rawValue))
                    continue
                }
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
                onInputEvent?(.keyUp(hardwareKeyEvent(for: press, modifiers: resolvedModifiers)))
            }
        }
        updateModifierRefreshTimer()
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputCaptureEnabled else {
            super.pressesCancelled(presses, with: event)
            return
        }

        let hardwareAvailable = refreshModifiersForInput()
        let allowFallback = !hardwareAvailable

        for press in presses {
            guard let key = press.key else { continue }
            let isCapsLockKey = key.keyCode == .keyboardCapsLock
            let fallbackFlags = key.modifierFlags
            let resolvedModifiers = resolvedHardwareKeyModifiers(
                from: event,
                fallbackFlags: fallbackFlags
            )

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
                let shortcut = MirageInterceptedShortcutPolicy.shortcut(
                    keyCode: MirageKeyEvent.hidToMacKeyCode(key.keyCode),
                    modifiers: resolvedModifiers
                )
                #if canImport(GameController)
                if clientShortcutClaimedKeyCodes.remove(key.keyCode) != nil {
                    gcClaimedKeyCodes.remove(GCKeyCode(rawValue: key.keyCode.rawValue))
                    continue
                }
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
                onInputEvent?(.keyUp(hardwareKeyEvent(for: press, modifiers: resolvedModifiers)))
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
        guard let press = heldKeyPresses[keyCode] else {
            return
        }
        let keyEvent = hardwareKeyEvent(for: press, modifiers: keyboardModifiers, isRepeat: true)
        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(keyEvent))
    }

    private func hardwareKeyEvent(
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

    /// Stop all active key repeat timers (call when view loses focus)
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
        guard shortcut.allowsRepeat else { return false }
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

    private func shouldSuppressClientShortcutDispatch(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) -> Bool {
        guard let lastDispatch = lastClientShortcutDispatch else { return false }
        guard lastDispatch.shortcut == shortcut else { return false }
        guard lastDispatch.source != source else { return false }
        return CFAbsoluteTimeGetCurrent() - lastDispatch.timestamp
            <= Self.passthroughShortcutDuplicateSuppressionWindow
    }

    private func noteClientShortcutDispatch(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) {
        lastClientShortcutDispatch = ClientShortcutDispatch(
            shortcut: shortcut,
            source: source,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    private func performClientShortcut(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) {
        guard onClientShortcut != nil else { return }
        guard !shouldSuppressClientShortcutDispatch(shortcut, source: source) else {
            return
        }
        noteClientShortcutDispatch(shortcut, source: source)
        onClientShortcut?(shortcut)
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

    private func performResponderShortcutAction(_ action: Selector) {
        guard inputCaptureEnabled else { return }
        guard let shortcut = editActionShortcut(for: action) else { return }
        if let clientShortcut = clientShortcut(for: shortcut) {
            performClientShortcut(clientShortcut, source: .responderAction)
            return
        }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    /// Override keyCommands to claim iPadOS system shortcuts that would otherwise be
    /// handled locally instead of reaching the remote host.
    override public var keyCommands: [UIKeyCommand]? {
        guard inputCaptureEnabled else { return nil }

        var commands: [UIKeyCommand] = []
        var claimedShortcutCommands: Set<ShortcutCommandIdentity> = []

        for action in actions {
            guard let binding = action.shortcut else { continue }
            let asShortcut = MirageClientShortcut(binding)
            guard let input = keyCommandInput(for: asShortcut) else { continue }
            let identity = ShortcutCommandIdentity(
                input: input,
                modifiers: binding.modifiers.normalizedForShortcutMatching
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handleClientShortcutCommand(_:)),
                input: input,
                modifierFlags: Self.uiKeyShortcutModifierFlags(from: binding.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        for shortcut in clientShortcuts {
            guard let input = keyCommandInput(for: shortcut) else { continue }
            let identity = ShortcutCommandIdentity(
                input: input,
                modifiers: shortcut.modifiers.normalizedForShortcutMatching
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handleClientShortcutCommand(_:)),
                input: input,
                modifierFlags: Self.uiKeyShortcutModifierFlags(from: shortcut.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        for shortcut in MirageInterceptedShortcutPolicy.shortcuts {
            let identity = ShortcutCommandIdentity(
                input: shortcut.input,
                modifiers: shortcut.modifiers
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: shortcut.input,
                modifierFlags: Self.uiKeyShortcutModifierFlags(from: shortcut.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        return commands
    }

    override public func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if shouldHandleResponderAction(action) {
            return self
        }
        return super.target(forAction: action, withSender: sender)
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if editActionShortcut(for: action) != nil {
            return shouldHandleResponderAction(action)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc
    func handleClientShortcutCommand(_ command: UIKeyCommand) {
        guard inputCaptureEnabled else { return }
        guard let input = command.input else { return }
        guard let keyCode = Self.characterToMacKeyCodeIfKnown(input)
            ?? Self.keyCode(forKeyCommandInput: input) else {
            return
        }
        let modifiers = MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        if let action = matchingAction(keyCode: keyCode, modifiers: modifiers) {
            performAction(action, source: .keyCommand)
            return
        }
        guard let shortcut = clientShortcut(keyCode: keyCode, modifiers: modifiers) else {
            return
        }
        performClientShortcut(shortcut, source: .keyCommand)
    }

    @objc
    func handlePassthroughShortcut(_ command: UIKeyCommand) {
        guard inputCaptureEnabled else { return }
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
        performResponderShortcutAction(#selector(toggleBoldface(_:)))
    }

    @objc
    public func undo(_: Any?) {
        performResponderShortcutAction(#selector(undo(_:)))
    }

    @objc
    public func redo(_: Any?) {
        performResponderShortcutAction(#selector(redo(_:)))
    }

    override public func toggleItalics(_: Any?) {
        performResponderShortcutAction(#selector(toggleItalics(_:)))
    }

    override public func toggleUnderline(_: Any?) {
        performResponderShortcutAction(#selector(toggleUnderline(_:)))
    }

    override public func find(_: Any?) {
        performResponderShortcutAction(#selector(find(_:)))
    }

    override public func findAndReplace(_: Any?) {
        performResponderShortcutAction(#selector(findAndReplace(_:)))
    }

    override public func findNext(_: Any?) {
        performResponderShortcutAction(#selector(findNext(_:)))
    }

    override public func findPrevious(_: Any?) {
        performResponderShortcutAction(#selector(findPrevious(_:)))
    }

    override public func selectAll(_: Any?) {
        performResponderShortcutAction(#selector(selectAll(_:)))
    }

    override public func printContent(_: Any?) {
        performResponderShortcutAction(#selector(printContent(_:)))
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

    private static func keyCode(forKeyCommandInput input: String) -> UInt16? {
        switch input {
        case UIKeyCommand.inputDelete:
            0x33
        case UIKeyCommand.inputEscape:
            0x35
        case UIKeyCommand.inputLeftArrow:
            0x7B
        case UIKeyCommand.inputRightArrow:
            0x7C
        case UIKeyCommand.inputDownArrow:
            0x7D
        case UIKeyCommand.inputUpArrow:
            0x7E
        default:
            MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode(input)
        }
    }
}
#endif
