//
//  InputCapturingView+GCKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController

enum GCKeyboardKeyRoutingDecision: Equatable {
    case ignore
    case action
    case clientShortcut
    case passthroughShortcut
    case forwardKey
}

extension InputCapturingView {
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
        let character = MirageClientKeyEventBuilder.characterToMacKeyCodeMap.first {
            $0.value == macKeyCode
        }?.key
        return MirageKeyEvent(
            keyCode: macKeyCode,
            characters: character,
            charactersIgnoringModifiers: character,
            modifiers: modifiers
        )
    }

    /// Handle a non-modifier key event from GCKeyboard.
    /// Only claims the event when modifiers are held; without modifiers, `pressesBegan`
    /// provides richer character data and is the better source.
    func handleGCKeyEvent(keyCode: GCKeyCode, isPressed: Bool) {
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
        guard responderRecoveryTarget == .captureView else { return false }
        return attemptResponderRecovery(for: .captureView)
    }

    func recoverFirstResponderForGCShortcutModifierIfNeeded() -> Bool {
        guard !isFirstResponder else { return true }
        guard window?.windowScene?.activationState == .foregroundActive else { return false }
        guard Self.shouldClaimGCForwardKey(
            modifiers: keyboardModifiers
        ) else {
            return false
        }
        guard responderRecoveryTarget == .captureView else { return false }
        return attemptResponderRecovery(for: .captureView)
    }
}
#endif
#endif
