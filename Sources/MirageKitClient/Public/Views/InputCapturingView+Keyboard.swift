//
//  InputCapturingView+Keyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
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
#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
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

    func updateModifierRefreshTimer() {
        if heldModifierKeys.isEmpty { stopModifierRefresh() } else {
            startModifierRefreshIfNeeded()
        }
    }

    static func uiKeyModifierFlags(
        from modifiers: MirageInput.MirageModifierFlags
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

    static func resolvedHardwareKeyModifiers(
        reportedModifiers: MirageInput.MirageModifierFlags?,
        trackedModifiers: MirageInput.MirageModifierFlags
    ) -> MirageInput.MirageModifierFlags {
        guard let reportedModifiers else { return trackedModifiers }
        return trackedModifiers.union(reportedModifiers)
    }

    private func resolvedHardwareKeyModifiers(
        from event: UIPressesEvent?,
        fallbackFlags: UIKeyModifierFlags?
    ) -> MirageInput.MirageModifierFlags {
        let reportedModifiers = modifierSnapshot(
            from: event,
            fallbackFlags: fallbackFlags,
            allowFallback: true
        )
        .map(MirageInput.MirageModifierFlags.init(uiKeyModifierFlags:))

        return Self.resolvedHardwareKeyModifiers(
            reportedModifiers: reportedModifiers,
            trackedModifiers: keyboardModifiers
        )
    }

    func clientShortcut(
        keyCode: UInt16,
        modifiers: MirageInput.MirageModifierFlags
    ) -> MirageClientShortcut? {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return clientShortcuts.first { shortcut in
            shortcut.keyCode == keyCode &&
                shortcut.modifiers.normalizedForShortcutMatching == normalizedModifiers
        }
    }

    // MARK: - Unified Action Matching

    func matchingAction(
        keyCode: UInt16,
        modifiers: MirageInput.MirageModifierFlags
    ) -> MirageInput.MirageAction? {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return actions.first { action in
            guard action.isEnabled else { return false }
            guard let binding = action.shortcut else { return false }
            return binding.keyCode == keyCode &&
                binding.modifiers.normalizedForShortcutMatching == normalizedModifiers
        }
    }

    func performAction(
        _ action: MirageInput.MirageAction,
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

    func keyCommandInput(
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
            MirageClientKeyEventBuilder.characterToMacKeyCodeMap.first {
                $0.value == shortcut.keyCode
            }?.key
        }
    }

    func shouldHandleResponderAction(_ action: Selector) -> Bool {
        guard let shortcut = editActionShortcut(for: action) else { return false }
        if clientShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) != nil {
            return onClientShortcut != nil
        }
        return onInputEvent != nil
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
                let macKeyCode = MirageInput.MirageKeyEvent.hidToMacKeyCode(key.keyCode)
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
        handlePressesEnding(presses, with: event)
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handlePressesEnding(presses, with: event)
    }

    /// Handles both ended and cancelled key presses, which share release cleanup semantics.
    private func handlePressesEnding(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
                    keyCode: MirageInput.MirageKeyEvent.hidToMacKeyCode(key.keyCode),
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
}
#endif
