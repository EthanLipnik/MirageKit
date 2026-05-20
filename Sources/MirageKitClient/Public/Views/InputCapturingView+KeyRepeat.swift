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
        stopModifiedKeyRepeat(sendKeyUp: true)
        lastClientShortcutDispatch = nil
        lastPassthroughShortcutDispatch = nil
    }

    // MARK: - Modified Key Repeat

    static func modifiedKeyRepeatEvent(for keyEvent: MirageKeyEvent) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: keyEvent.keyCode,
            characters: keyEvent.characters,
            charactersIgnoringModifiers: keyEvent.charactersIgnoringModifiers,
            modifiers: keyEvent.modifiers,
            isRepeat: true
        )
    }

    static func modifiedKeyRepeatKeyUpEvent(
        for keyEvent: MirageKeyEvent,
        modifiers: MirageModifierFlags
    ) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: keyEvent.keyCode,
            characters: keyEvent.characters,
            charactersIgnoringModifiers: keyEvent.charactersIgnoringModifiers,
            modifiers: modifiers,
            isRepeat: false
        )
    }

    static func shouldContinueModifiedKeyRepeat(
        keyIsPressed: Bool,
        currentModifiers: MirageModifierFlags,
        requiredModifiers: MirageModifierFlags
    ) -> Bool {
        keyIsPressed &&
            currentModifiers.normalizedForShortcutMatching
            .isSuperset(of: requiredModifiers.normalizedForShortcutMatching)
    }

    #if canImport(GameController)
    func startModifiedKeyRepeat(
        keyCode: GCKeyCode,
        keyEvent: MirageKeyEvent,
        requiredModifiers: MirageModifierFlags
    ) {
        let normalizedRequiredModifiers = requiredModifiers.normalizedForShortcutMatching
        if let existing = modifiedKeyRepeatState,
           existing.keyCode == keyCode,
           existing.keyEvent.keyCode == keyEvent.keyCode,
           existing.requiredModifiers == normalizedRequiredModifiers {
            return
        }

        stopModifiedKeyRepeat(sendKeyUp: true)
        modifiedKeyRepeatState = ModifiedKeyRepeatState(
            keyCode: keyCode,
            keyEvent: keyEvent,
            requiredModifiers: normalizedRequiredModifiers,
            nextRepeatDeadline: Date.timeIntervalSinceReferenceDate + Self.keyRepeatInitialDelay
        )

        if modifiedKeyRepeatTimer == nil {
            modifiedKeyRepeatTimer = Timer
                .scheduledTimer(
                    withTimeInterval: Self.passthroughShortcutRepeatPollInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.tickModifiedKeyRepeat()
                }
        }
    }

    @discardableResult
    func stopModifiedKeyRepeat(
        for keyCode: GCKeyCode? = nil,
        sendKeyUp: Bool
    ) -> Bool {
        guard let state = modifiedKeyRepeatState else { return false }
        if let keyCode, state.keyCode != keyCode { return false }

        modifiedKeyRepeatState = nil
        modifiedKeyRepeatTimer?.invalidate()
        modifiedKeyRepeatTimer = nil

        if sendKeyUp {
            onInputEvent?(
                .keyUp(Self.modifiedKeyRepeatKeyUpEvent(
                    for: state.keyEvent,
                    modifiers: keyboardModifiers
                ))
            )
        }
        return true
    }

    func stopModifiedKeyRepeatIfRequiredModifiersReleased() {
        guard let state = modifiedKeyRepeatState else { return }
        guard isModifiedKeyRepeatHeld(keyCode: state.keyCode, requiredModifiers: state.requiredModifiers) else {
            stopModifiedKeyRepeat(sendKeyUp: true)
            return
        }
    }

    func tickModifiedKeyRepeat() {
        guard var state = modifiedKeyRepeatState else {
            modifiedKeyRepeatTimer?.invalidate()
            modifiedKeyRepeatTimer = nil
            return
        }

        guard isModifiedKeyRepeatHeld(keyCode: state.keyCode, requiredModifiers: state.requiredModifiers) else {
            stopModifiedKeyRepeat(sendKeyUp: true)
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard now >= state.nextRepeatDeadline else { return }

        hideCursorForTypingUntilPointerMovement()
        onInputEvent?(.keyDown(Self.modifiedKeyRepeatEvent(for: state.keyEvent)))
        state.nextRepeatDeadline = now + Self.keyRepeatInterval
        modifiedKeyRepeatState = state
    }

    func isModifiedKeyRepeatHeld(
        keyCode: GCKeyCode,
        requiredModifiers: MirageModifierFlags
    ) -> Bool {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        let keyIsPressed = keyboardInput.button(forKeyCode: keyCode)?.isPressed == true
        let currentModifiers = hardwareModifiers(from: keyboardInput)
        return Self.shouldContinueModifiedKeyRepeat(
            keyIsPressed: keyIsPressed,
            currentModifiers: currentModifiers,
            requiredModifiers: requiredModifiers
        )
    }

    func hardwareModifiers(from keyboardInput: GCKeyboardInput) -> MirageModifierFlags {
        var modifiers: MirageModifierFlags = []
        if keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true ||
            keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true {
            modifiers.insert(.shift)
        }
        if keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true ||
            keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true {
            modifiers.insert(.control)
        }
        if keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true ||
            keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true {
            modifiers.insert(.option)
        }
        if keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true ||
            keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true {
            modifiers.insert(.command)
        }
        return modifiers
    }

    static func gcKeyCode(forMacKeyCode keyCode: UInt16) -> GCKeyCode? {
        guard let hidUsage = macKeyCodeToHIDUsageMap[keyCode] else { return nil }
        return GCKeyCode(rawValue: hidUsage.rawValue)
    }

    private static let macKeyCodeToHIDUsageMap: [UInt16: UIKeyboardHIDUsage] = [
        0x00: .keyboardA,
        0x0B: .keyboardB,
        0x08: .keyboardC,
        0x02: .keyboardD,
        0x0E: .keyboardE,
        0x03: .keyboardF,
        0x05: .keyboardG,
        0x04: .keyboardH,
        0x22: .keyboardI,
        0x26: .keyboardJ,
        0x28: .keyboardK,
        0x25: .keyboardL,
        0x2E: .keyboardM,
        0x2D: .keyboardN,
        0x1F: .keyboardO,
        0x23: .keyboardP,
        0x0C: .keyboardQ,
        0x0F: .keyboardR,
        0x01: .keyboardS,
        0x11: .keyboardT,
        0x20: .keyboardU,
        0x09: .keyboardV,
        0x0D: .keyboardW,
        0x07: .keyboardX,
        0x10: .keyboardY,
        0x06: .keyboardZ,
        0x12: .keyboard1,
        0x13: .keyboard2,
        0x14: .keyboard3,
        0x15: .keyboard4,
        0x17: .keyboard5,
        0x16: .keyboard6,
        0x1A: .keyboard7,
        0x1C: .keyboard8,
        0x19: .keyboard9,
        0x1D: .keyboard0,
        0x2B: .keyboardComma,
        0x2F: .keyboardPeriod,
        0x2C: .keyboardSlash,
        0x29: .keyboardSemicolon,
        0x27: .keyboardQuote,
        0x21: .keyboardOpenBracket,
        0x1E: .keyboardCloseBracket,
        0x2A: .keyboardBackslash,
        0x1B: .keyboardHyphen,
        0x18: .keyboardEqualSign,
        0x32: .keyboardGraveAccentAndTilde,
        0x31: .keyboardSpacebar,
        0x30: .keyboardTab,
        0x24: .keyboardReturnOrEnter,
        0x33: .keyboardDeleteOrBackspace,
        0x35: .keyboardEscape,
        0x7B: .keyboardLeftArrow,
        0x7C: .keyboardRightArrow,
        0x7D: .keyboardDownArrow,
        0x7E: .keyboardUpArrow,
        0x75: .keyboardDeleteForward,
    ]
    #else
    @discardableResult
    func stopModifiedKeyRepeat(sendKeyUp _: Bool) -> Bool {
        false
    }

    func stopModifiedKeyRepeatIfRequiredModifiersReleased() {}
    #endif

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
        #if canImport(GameController)
        guard let keyCode = Self.gcKeyCode(forMacKeyCode: shortcut.keyCode) else { return false }
        let eventModifiers = shortcut.forwardedModifiers(baseModifiers: baseModifiers)

        if let existing = modifiedKeyRepeatState {
            if existing.keyCode == keyCode,
               existing.keyEvent.keyCode == shortcut.keyCode,
               existing.keyEvent.characters == shortcut.input,
               existing.requiredModifiers == eventModifiers.normalizedForShortcutMatching {
                return true
            }
            stopModifiedKeyRepeat(sendKeyUp: true)
        }

        sendPassthroughShortcutKeyDown(
            shortcut: shortcut,
            baseModifiers: baseModifiers,
            isRepeat: false
        )

        guard isModifiedKeyRepeatHeld(
            keyCode: keyCode,
            requiredModifiers: eventModifiers.normalizedForShortcutMatching
        ) else {
            sendPassthroughShortcutKeyUp(
                shortcut: shortcut,
                baseModifiers: baseModifiers
            )
            return true
        }

        startModifiedKeyRepeat(
            keyCode: keyCode,
            keyEvent: shortcut.keyDownEvent(baseModifiers: baseModifiers),
            requiredModifiers: eventModifiers.normalizedForShortcutMatching
        )

        return true
        #else
        return false
        #endif
    }
}
#endif
